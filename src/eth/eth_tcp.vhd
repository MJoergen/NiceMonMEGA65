-- A small TCP server (RFC 9293) for the debug link: one connection at a
-- time, on port G_PORT of ip_i, which carries the link's two byte streams,
-- as the UART does (nicemon.vhd). It reads the received frames of
-- eth_rx_fifo.vhd alongside eth_arp.vhd and eth_icmp.vhd, and writes its
-- segments to eth_tx_fifo.vhd. ip_i at 0 turns it off.
--
-- THEORY OF OPERATION
-- The connection is the line. While there is one (on_o), the link's input
-- comes from it and its output goes to it. A connection is one from the
-- host's ACK of the SYN-ACK on, so that a SYN alone, as of a port scan,
-- leaves the link on the UART. The host's half-close, its FIN, is a break
-- of the line (rx_break_o), after the last byte before it (brk_ptr). The
-- link stays with the connection after its end, by an RST or the tries,
-- until it has taken all the input and the break (drain), so that none is
-- lost, and a cycle more, as on_o follows drain through a register, for
-- the timing; the output in that time is dropped. The states are those of
-- a passive open, and of a close:
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
-- fits (wr_ok, known before the data starts). In the cycle after the last
-- byte (eval), with the stream held, the segment is acted on if it is
-- good; its data is committed (rx_cmt) only then, and rcv_nxt moves past
-- it. Every segment with data or
-- a FIN gets an ACK (ack_req), also one that is out of order, which is
-- dropped, so the host sends it again; so does one without either whose
-- sequence number is not rcv_nxt, such as a keepalive probe. A segment
-- that overlaps data already taken is dropped whole, and the host sends
-- it again from the sequence number of the ACK.
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
-- What may be sent is worked out in one cycle (B_IDLE) and the segment
-- chosen in the next (B_PICK), for the timing; the choice is dropped if a
-- segment is read or the timer runs out in that cycle, as both change
-- what may be sent. The segment's header fields (seg_*) and where its
-- data is go to eth_tcp_tx.vhd, which builds it, with the checksums, and
-- sends it; nothing is chosen while it is busy.
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
   signal tail_ptr  : t_ptr                         := (others => '0');
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
   -- The timers: a millisecond, the retransmission timeout, and its count
   signal tick_cnt : natural range 0 to C_TICK     := 0;
   signal rto_cnt  : natural range 0 to C_RTO_MS   := 0;
   signal tries    : natural range 0 to C_TRIES    := 0;
   -- The initial sequence number, a cycle counter
   signal isn : std_logic_vector(31 downto 0) := (others => '0');
   -- Cycles since the link's last output byte
   signal idle : natural range 0 to C_IDLE     := 0;
   -- The receive window of the last segment sent
   signal adv_wnd : natural range 0 to C_SIZE     := 0;

   -- The segment read (eth_tcp_rx.vhd), in the cycle after its last byte
   signal eval    : std_logic;
   signal good    : std_logic;
   signal f_smac  : std_logic_vector(47 downto 0);
   signal f_sip   : std_logic_vector(31 downto 0);
   signal f_sport : std_logic_vector(15 downto 0);
   signal f_seq   : std_logic_vector(31 downto 0);
   signal f_ack   : std_logic_vector(31 downto 0);
   signal f_flags : std_logic_vector(7 downto 0);
   signal f_win   : std_logic_vector(15 downto 0);
   signal plen    : integer range -80 to 2 ** 16;
   signal wr_ok   : std_logic;
   -- The connection takes data.
   signal take : std_logic;

   -- The receive buffer
   signal rx_wr     : t_ptr                        := (others => '0');
   signal rx_cmt    : t_ptr                        := (others => '0');
   signal rx_rd     : t_ptr                        := (others => '0');
   signal rx_free   : natural range 0 to C_SIZE;
   signal rx_we     : std_logic;
   signal rx_rdata  : std_logic_vector(8 downto 0);
   signal lfetch    : std_logic                    := '0';
   signal lrx_valid : std_logic                    := '0';
   signal fin_rcvd  : std_logic                    := '0';
   -- The host's FIN has come.
   signal peer_fin : std_logic                    := '0';
   signal brk_ptr  : t_ptr                        := (others => '0');
   -- Input or a break that the link has not taken, and the same a cycle
   -- later, which on_o follows
   signal drain   : std_logic;
   signal drain_r : std_logic                    := '0';

   -- The send buffer
   signal tx_we    : std_logic;
   signal tx_ready : std_logic;
   signal tx_raddr : std_logic_vector(G_ADDR_BITS - 1 downto 0);
   signal tx_rdata : std_logic_vector(8 downto 0);

   -- The segment being chosen, and the one being sent
   type   t_build is (B_IDLE, B_PICK);
   signal build     : t_build                       := B_IDLE;
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
   -- The data that may be sent: its length, and whether it is a whole
   -- segment
   signal pick_n   : natural range 0 to C_MSS := 0;
   signal pick_big : boolean                  := false;
   signal seg_n    : natural range 0 to C_MSS := 0;

   signal conn : std_logic;

begin

   conn <= '1' when state = EST_ST or state = CLOSE_WAIT_ST or state = LAST_ACK_ST or
                    (state = SYN_RCVD_ST and keep = '1') else
           '0';
   on_o <= conn or drain_r;

   ---------------------------------------------------------------------------
   -- Receive
   ---------------------------------------------------------------------------

   rx_free <= C_SIZE - to_integer(rx_cmt - rx_rd);
   take    <= '1' when state /= LISTEN_ST and peer_fin = '0' else
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
         wr_ok_o    => wr_ok,
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
         len_o      => plen
      ); -- i_eth_tcp_rx


   i_rx_ram : entity work.eth_ram
      generic map (
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         wr_clk_i  => clk_i,
         wr_we_i   => rx_we,
         wr_addr_i => rx_wr(G_ADDR_BITS - 1 downto 0),
         wr_data_i => '0' & rx_data_i,
         rd_clk_i  => clk_i,
         rd_addr_i => rx_rd(G_ADDR_BITS - 1 downto 0),
         rd_data_o => rx_rdata
      ); -- i_rx_ram

   lrx_valid_o <= lrx_valid;
   drain       <= '1' when rx_rd /= rx_cmt or lfetch = '1' or lrx_valid = '1' or
                           fin_rcvd = '1' else
                  '0';

   ---------------------------------------------------------------------------
   -- Send
   ---------------------------------------------------------------------------

   tx_ready    <= '1' when conn = '1' and to_integer(tail_ptr - una_ptr) < C_SIZE else
                  '0';
   ltx_ready_o <= tx_ready or not conn;
   tx_we       <= ltx_valid_i and tx_ready;
   lim_ptr     <= fin_ptr when closing = '1' else
                  tail_ptr;

   i_tx_ram : entity work.eth_ram
      generic map (
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         wr_clk_i  => clk_i,
         wr_we_i   => tx_we,
         wr_addr_i => tail_ptr(G_ADDR_BITS - 1 downto 0),
         wr_data_i => '0' & ltx_data_i,
         rd_clk_i  => clk_i,
         rd_addr_i => tx_raddr,
         rd_data_o => tx_rdata
      ); -- i_tx_ram


   i_eth_tcp_tx : entity work.eth_tcp_tx
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
         rd_addr_o   => tx_raddr,
         rd_data_i   => tx_rdata(7 downto 0),
         tx_data_o   => tx_data_o,
         tx_last_o   => tx_last_o,
         tx_valid_o  => tx_valid_o,
         tx_ready_i  => tx_ready_i
      ); -- i_eth_tcp_tx


   p_tcp : process (clk_i)
      variable from_peer_v : boolean;
      variable syn_v       : boolean;
      variable k_v         : std_logic_vector(31 downto 0);
      variable d1_v        : std_logic_vector(31 downto 0);
      variable d2_v        : std_logic_vector(31 downto 0);
      variable rcv_v       : std_logic_vector(31 downto 0);
      variable avail_v     : natural range 0 to C_SIZE;
      variable room_v      : integer range -C_SIZE to 2 ** 16;
      variable n_v         : natural range 0 to C_MSS;
      variable timeout_v   : boolean;
      variable go_v        : boolean;

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
         tries     <= 0;
         rto_cnt   <= 0;
      end procedure accept;

      -- Ends the connection, and opens the one that waits, if any. Its
      -- received data ends at cmt.
      procedure finish (
         cmt : t_ptr
      ) is
      begin
         if pend = '1' then
            accept(pend_mac, pend_ip, pend_port, pend_seq, pend_win, fin_ptr);
            keep <= '1';
            -- The old connection's input has ended.
            if peer_fin = '0' then
               fin_rcvd <= '1';
               brk_ptr  <= cmt;
            end if;
         else
            state   <= LISTEN_ST;
            keep    <= '0';
            fin_ack <= '0';
         end if;
      end procedure finish;

   begin
      if rising_edge(clk_i) then
         isn <= isn + 1;

         -- The milliseconds
         if tick_cnt = C_TICK - 1 then
            tick_cnt <= 0;
         else
            tick_cnt <= tick_cnt + 1;
         end if;

         -- The link's output
         if tx_we = '1' then
            tail_ptr <= tail_ptr + 1;
            idle     <= 0;
         elsif idle < C_IDLE then
            idle <= idle + 1;
         end if;

         -- The receive buffer to the link, and the host's half-close after
         -- the last byte before it
         lrx_break_o <= '0';
         if lrx_ready_i = '1' then
            lrx_valid <= '0';
         end if;
         if lfetch = '1' then
            lrx_data_o <= rx_rdata(7 downto 0);
            lrx_valid  <= '1';
         end if;
         lfetch <= '0';
         if lfetch = '0' and rx_rd /= rx_cmt and not (fin_rcvd = '1' and rx_rd = brk_ptr) and
            (lrx_valid = '0' or lrx_ready_i = '1') then
            lfetch <= '1';
            rx_rd  <= rx_rd + 1;
         end if;
         if fin_rcvd = '1' and rx_rd = brk_ptr and lfetch = '0' and lrx_valid = '0' then
            lrx_break_o <= '1';
            fin_rcvd    <= '0';
         end if;
         drain_r <= drain;

         -- A window that has grown is told.
         if state = EST_ST and rx_free >= adv_wnd + C_WND_STEP then
            ack_req <= '1';
         end if;

         -- A segment's data, as it comes
         if rx_we = '1' then
            rx_wr <= rx_wr + 1;
         end if;

         ------------------------------------------------------------------
         -- The segment, in the cycle after its last byte
         ------------------------------------------------------------------
         timeout_v := false;
         if eval = '1' then
            rx_wr <= rx_cmt;

            if good = '1' and ip_i /= 0 then
               from_peer_v := f_sip = peer_ip and f_sport = peer_port;
               syn_v       := f_flags(1) = '1' and f_flags(4) = '0' and f_flags(2) = '0';

               if syn_v then

                  case state is

                     when LISTEN_ST =>
                        accept(f_smac, f_sip, f_sport, f_seq, f_win, tail_ptr);

                     when SYN_RCVD_ST =>
                        -- Another SYN replaces it; the output after its base,
                        -- if the link is kept, goes to the new one.
                        if from_peer_v and f_seq = irs then
                           syn_req <= '1';
                        else
                           accept(f_smac, f_sip, f_sport, f_seq, f_win, una_ptr);
                        end if;

                     when EST_ST | CLOSE_WAIT_ST | LAST_ACK_ST =>
                        if from_peer_v and f_seq = irs then
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

               elsif from_peer_v and state /= LISTEN_ST then
                  if f_flags(2) = '1' then
                     -- A reset, with a sequence number in the window
                     if f_seq - rcv_nxt < C_SIZE then
                        finish(rx_cmt);
                     end if;
                  elsif state = SYN_RCVD_ST and not (f_flags(4) = '1' and f_ack = iss + 1) then
                     -- Nothing but the ACK of the SYN-ACK opens the connection.
                     null;
                  else
                     -- The ACK of the SYN-ACK, which may carry data and a FIN
                     if state = SYN_RCVD_ST then
                        state   <= EST_ST;
                        keep    <= '0';
                        tries   <= 0;
                        rto_cnt <= 0;
                     end if;

                     -- The ACK: the bytes it covers are free.
                     if f_flags(4) = '1' then
                        k_v  := f_ack - una_seq;
                        d1_v := f_seq - snd_wl1;
                        d2_v := f_ack - snd_wl2;
                        if k_v <= max_ptr - una_ptr and
                           ((d1_v /= 0 and d1_v(31) = '0') or (d1_v = 0 and d2_v(31) = '0')) then
                           snd_wnd <= f_win;
                           snd_wl1 <= f_seq;
                           snd_wl2 <= f_ack;
                           if f_win = 0 then
                              tries <= 0;
                           end if;
                        end if;
                        if k_v /= 0 and k_v <= max_ptr - una_ptr then
                           una_ptr <= una_ptr + k_v(G_ADDR_BITS downto 0);
                           una_seq <= f_ack;
                           if k_v > nxt_ptr - una_ptr then
                              nxt_ptr <= una_ptr + k_v(G_ADDR_BITS downto 0);
                           end if;
                           tries   <= 0;
                           rto_cnt <= 0;
                        end if;
                     end if;

                     -- The data, which was written if it is the next
                     rcv_v := rcv_nxt;
                     if wr_ok = '1' then
                        rx_cmt <= rx_wr;
                        rx_wr  <= rx_wr;
                        rcv_v  := rcv_nxt + plen;
                     end if;
                     -- Data, a FIN, or a segment that is not the next, as a
                     -- keepalive probe at rcv_nxt - 1 is, gets an ACK.
                     if plen > 0 or f_flags(0) = '1' or f_seq /= rcv_nxt then
                        ack_req <= '1';
                     end if;
                     -- The host's FIN, if all before it has come
                     if f_flags(0) = '1' and peer_fin = '0' and f_seq + plen = rcv_v then
                        rcv_v    := rcv_v + 1;
                        if state = EST_ST or state = SYN_RCVD_ST then
                           state <= CLOSE_WAIT_ST;
                        end if;
                        peer_fin <= '1';
                        fin_rcvd <= '1';
                        if wr_ok = '1' then
                           brk_ptr <= rx_wr;
                        else
                           brk_ptr <= rx_cmt;
                        end if;
                     end if;
                     rcv_nxt <= rcv_v;

                     -- The ACK of this side's FIN ends the connection.
                     if state = LAST_ACK_ST and fin_max = '1' and f_flags(4) = '1' and
                        f_ack = una_seq + (fin_ptr - una_ptr) + 1 then
                        fin_ack <= '1';
                     end if;
                  end if;
               end if;
            end if;

         -- The end, once the ACK that the host is owed is sent; as for a
         -- timeout, the segment being chosen is dropped.
         elsif fin_ack = '1' and ack_req = '0' and busy = '0' then
            timeout_v := true;
            finish(rx_cmt);

         ------------------------------------------------------------------
         -- The retransmission timer
         ------------------------------------------------------------------
         elsif tick_cnt = C_TICK - 1 then
            if state = SYN_RCVD_ST or max_ptr /= una_ptr or
               (state = LAST_ACK_ST and fin_max = '1') or
               (conn = '1' and snd_wnd = 0 and lim_ptr /= una_ptr) then
               if rto_cnt = C_RTO_MS - 1 then
                  rto_cnt   <= 0;
                  timeout_v := true;
                  if tries = C_TRIES - 1 then
                     finish(rx_cmt);
                  else
                     tries    <= tries + 1;
                     nxt_ptr  <= una_ptr;
                     fin_sent <= '0';
                     if snd_wnd = 0 then
                        probe <= '1';
                     end if;
                     if state = SYN_RCVD_ST then
                        syn_req <= '1';
                     end if;
                  end if;
               else
                  rto_cnt <= rto_cnt + 1;
               end if;
            else
               rto_cnt <= 0;
               tries   <= 0;
            end if;
         end if;

         ------------------------------------------------------------------
         -- The segment to send: the SYN-ACK, data, the FIN, or an ACK
         ------------------------------------------------------------------
         go <= '0';

         case build is

            -- What may be sent: computed here, once the last segment has
            -- gone, and chosen from in the next cycle, unless a segment was
            -- read or the timer ran out in it.
            when B_IDLE =>
               if eval = '0' and not timeout_v and busy = '0' then
                  avail_v := to_integer(lim_ptr - nxt_ptr);
                  room_v  := to_integer(snd_wnd) - to_integer(nxt_ptr - una_ptr);
                  if room_v < 0 then
                     room_v := 0;
                  end if;
                  n_v      := minimum(minimum(avail_v, room_v), C_MSS);
                  pick_n   <= n_v;
                  pick_big <= avail_v >= C_MSS;
                  if probe = '1' and room_v = 0 and avail_v > 0 then
                     pick_n   <= 1;
                     pick_big <= true;
                  end if;

                  seg_mac  <= peer_mac;
                  seg_ip   <= peer_ip;
                  seg_port <= peer_port;
                  seg_ack  <= rcv_nxt;
                  seg_wnd  <= X"0000" + rx_free;
                  seg_ptr  <= nxt_ptr;
                  seg_n    <= 0;
                  -- After this side's FIN, the next sequence number is past it.
                  seg_seq  <= una_seq + (nxt_ptr - una_ptr) + fin_sent;
                  build    <= B_PICK;
               end if;

            when B_PICK =>
               go_v  := false;
               build <= B_IDLE;
               if eval = '0' and not timeout_v then
                  if syn_req = '1' and state = SYN_RCVD_ST then
                     seg_flags <= C_SYN or C_ACK;
                     seg_seq   <= iss;
                     syn_req   <= '0';
                     go_v      := true;
                  elsif state /= LISTEN_ST and state /= SYN_RCVD_ST and pick_n > 0 and
                        (pick_big or idle = C_IDLE or closing = '1') then
                     seg_flags <= C_ACK or C_PSH;
                     seg_n     <= pick_n;
                     probe     <= '0';
                     nxt_ptr   <= nxt_ptr + pick_n;
                     if nxt_ptr + pick_n - una_ptr > max_ptr - una_ptr then
                        max_ptr <= nxt_ptr + pick_n;
                     end if;
                     go_v := true;
                  elsif state /= LISTEN_ST and state /= SYN_RCVD_ST and closing = '1' and
                        nxt_ptr = fin_ptr and fin_sent = '0' then
                     seg_flags <= C_FIN or C_ACK;
                     fin_sent  <= '1';
                     fin_max   <= '1';
                     state     <= LAST_ACK_ST;
                     go_v      := true;
                  elsif ack_req = '1' and state /= LISTEN_ST and state /= SYN_RCVD_ST then
                     seg_flags <= C_ACK;
                     go_v      := true;
                  end if;

                  -- Every segment acknowledges, with the window of now.
                  if go_v then
                     ack_req <= '0';
                     adv_wnd <= rx_free;
                     go      <= '1';
                  end if;
               end if;

         end case;

         if rst_i = '1' then
            state     <= LISTEN_ST;
            una_ptr   <= (others => '0');
            nxt_ptr   <= (others => '0');
            max_ptr   <= (others => '0');
            tail_ptr  <= (others => '0');
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
            rx_rd     <= (others => '0');
            lfetch    <= '0';
            lrx_valid <= '0';
            fin_rcvd  <= '0';
            drain_r   <= '0';
            peer_fin  <= '0';
            build     <= B_IDLE;
            go        <= '0';
         end if;
      end if;
   end process p_tcp;

end architecture synthesis;
