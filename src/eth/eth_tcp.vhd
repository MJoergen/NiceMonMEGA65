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
-- of the line (lrx_break_o), after the last byte committed (cmt). The
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
-- if its FIN has not come by then, the end is a break. A SYN from
-- another IP address gets a RST while a connection is open.
--
-- Receive: eth_tcp_rx.vhd reads a frame a byte at a time, keeps the
-- fields of a TCP segment to this station, and checks its checksums. The
-- segment's data goes into the receive buffer as it comes (rx_we), if it
-- is the next data of the connection (its sequence number is rcv_nxt) and
-- fits (wr_ok, known before the data starts). The parser offers the
-- segment from the second cycle after the last byte, with the stream
-- held, and the connection takes it (eval) once p_cmp has compared it
-- with the connection as it is; it is acted on then, if it is good; its
-- data is committed (cmt) only then, if it is still the next, as the
-- connection may have ended and another opened meanwhile, and rcv_nxt
-- moves past it, or else
-- it is discarded (discard), and the next segment's data goes where it
-- went. Its sequence and acknowledgment numbers are compared with the
-- connection's in registers (p_cmp), a cycle behind, for the timing; they
-- stand at eval, for the fields have been there since the frame's byte
-- 49, and the connection's numbers since the last segment acted on, but
-- in the cycle after the connection ended or the timer ran out (stale),
-- when p_cmp still has the connection before that, so the segment waits
-- that cycle. Every segment with data or a FIN gets an ACK (ack_req), also
-- one that is out of order, which is dropped, so the host sends it again;
-- so does one without either whose sequence number is not rcv_nxt, such
-- as a keepalive probe. A segment that overlaps data already taken is
-- dropped whole, and the host sends it again from the sequence number of
-- the ACK. Once the connection is open, a segment without ACK is dropped,
-- and one whose ACK is of what was not sent gets an ACK and is dropped,
-- data and all (RFC 9293 3.10.7.4); an old ACK, before una_seq, is not
-- taken, but its segment's data is. A SYN with data or a FIN opens a
-- connection for the SYN alone, and the host sends the rest again.
--
-- Send: the link's output goes into the send buffer at tail_ptr. una_ptr
-- is the first byte not yet acknowledged, whose sequence number is
-- una_seq, nxt_ptr the next to send, and max_ptr the highest sent. The
-- data goes out in segments of at most C_MSS bytes, as much as the host's
-- window takes, when there are C_MSS bytes or the output has paused for
-- C_IDLE cycles, so that one answer of the link goes in few segments. An
-- ACK of the host frees the bytes it covers, for the link's output only
-- once the segment that is being sent has gone (buf_una), as it may still
-- read them, if the ACK came while it was sent again. If nothing new is
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
-- same reason the host sends segments of at most 536 bytes. A segment
-- that fits no connection, and is no RST itself, gets a RST (refuse, RFC
-- 9293 3.10.7.1): at its acknowledgment number, if it has an ACK, and
-- otherwise with an ACK past its data, SYN, and FIN; so does an ACK that
-- is not of the SYN-ACK in SYN_RCVD_ST (3.10.7.4). Those are a SYN from
-- another IP address while a connection is open, the segments of a
-- connection that has ended, and any but a SYN in LISTEN_ST. The RST goes
-- to the segment's source, from its fields kept in rst_*, after what the
-- connection has to send, so that a flood of such segments does not hold
-- that back; one waits at a time, and the next is dropped while it does,
-- for its host sends it again. Segments to other ports never come here
-- (eth_tcp_rx.vhd), and get nothing. A segment belongs to
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
-- one of them that it cannot read is a pulse (cmt, discard, brk_set,
-- restart, tries_clr), which lands a cycle later; each says why that is
-- in time.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) mac_i and ip_i stay stable while there is a connection.
-- b) G_CLOCK_HZ is the clock's rate, at least 2000, for the timers.
--
-- With G_FORMAL, it states the properties that formal/eth_tcp.sby proves
-- for the connection, with a free parser and chooser: the pointers of the
-- send buffer stay in order, within the buffer, and not past fin_ptr
-- while closing; the connection opens, and the link goes to it, only by
-- the ACK of its SYN-ACK; rcv_nxt is the host's first number past the
-- data committed and its FIN, and data is committed only from the peer,
-- at rcv_nxt; every segment with data, a FIN, or another sequence number
-- gets an ACK, which stays asked for until it is sent; una_seq is the
-- number of the byte at una_ptr, which moves only to what an ACK covers;
-- the host's window is taken only as RFC 9293 3.10.7.4 says; the
-- connection ends only by a reset in the window, the last try, or the
-- ACK of this side's FIN; the break comes once per connection, as the
-- host's FIN comes or at the end without one; with ip_i at 0, nothing
-- opens and nothing is sent; and the server keeps the contracts of the
-- timer, the buffers, and the chooser. p_cmp's registers stand for the
-- segment offered but in the cycle after it is stale. It assumes the
-- parser's promise that a good segment whose data was written has had
-- all of it written, and turns on the properties of the buffers and the
-- timer.
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
      G_ADDR_BITS : natural := 11;
      -- The longest segment, the pause of the output that sends what
      -- there is, the retransmission timeout, and its tries, smaller in
      -- the formal job
      G_MSS       : natural := 536;
      G_IDLE      : natural := 64;
      G_RTO_MS    : natural := 300;
      G_TRIES     : natural := 17;
      -- The properties for formal/eth_tcp.sby
      G_FORMAL    : boolean := false
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
   constant C_MSS      : natural := G_MSS;
   constant C_IDLE     : natural := G_IDLE;
   constant C_RTO_MS   : natural := G_RTO_MS;
   constant C_TRIES    : natural := G_TRIES;
   constant C_TICK     : natural := G_CLOCK_HZ / 1000;
   constant C_WND_STEP : natural := C_SIZE / 2;

   subtype t_ptr is std_logic_vector(G_ADDR_BITS downto 0);

   type   t_state is (LISTEN_ST, SYN_RCVD_ST, EST_ST, CLOSE_WAIT_ST, LAST_ACK_ST);
   signal state : t_state := LISTEN_ST;

   -- The connection: the host, and its numbers
   signal peer    : t_host                        := C_HOST_NONE;
   signal irs     : std_logic_vector(31 downto 0) := (others => '0');
   signal rcv_nxt : std_logic_vector(31 downto 0) := (others => '0');
   signal iss     : std_logic_vector(31 downto 0) := (others => '0');
   signal una_seq : std_logic_vector(31 downto 0) := (others => '0');
   signal snd_wnd : std_logic_vector(15 downto 0) := (others => '0');
   signal snd_wl1 : std_logic_vector(31 downto 0) := (others => '0');
   signal snd_wl2 : std_logic_vector(31 downto 0) := (others => '0');
   signal una_ptr : t_ptr                         := (others => '0');
   -- una_ptr for the send buffer's room, which waits while a segment is
   -- sent
   signal buf_una : t_ptr                         := (others => '0');
   signal nxt_ptr : t_ptr                         := (others => '0');
   signal max_ptr : t_ptr                         := (others => '0');
   signal fin_ptr : t_ptr                         := (others => '0');
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
   -- A RST to send (refuse), with ACK or not, to the source of the
   -- segment that fits no connection; with ACK, rst_num is its
   -- acknowledgment number, and without, its sequence number.
   signal rst_req  : std_logic                     := '0';
   signal rst_ack  : std_logic                     := '0';
   signal rst_host : t_host                        := C_HOST_NONE;
   signal rst_num  : std_logic_vector(31 downto 0) := (others => '0');
   -- One byte goes beyond the host's window of 0.
   signal probe : std_logic                     := '0';
   -- The SYN of the next connection
   signal pend : std_logic                     := '0';
   -- The connection that waits for the ACK of its SYN-ACK came from pend,
   -- and has the link
   signal keep : std_logic                     := '0';
   -- Its host is from the connection's IP address, so pend_host.ip is not
   -- read.
   signal pend_host : t_host                        := C_HOST_NONE;
   signal pend_seq  : std_logic_vector(31 downto 0) := (others => '0');
   signal pend_win  : std_logic_vector(15 downto 0) := (others => '0');
   -- The retransmission timer (eth_tcp_timer.vhd) runs, and the same a
   -- cycle later, which the timer takes; it runs out, and is on its last
   -- try
   signal armed    : std_logic;
   signal armed_r  : std_logic := '0';
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

   -- The segment read (eth_tcp_rx.vhd), offered from the second cycle
   -- after its last byte, and taken (eval) once p_cmp has compared it
   -- with the connection as it is: not in the cycle after the connection
   -- ended or the timer ran out (stale), as p_cmp is a cycle behind
   signal seg_valid : std_logic;
   signal seg_ready : std_logic;
   signal stale     : std_logic := '0';
   signal eval      : std_logic;
   signal good      : std_logic;
   signal f_seg     : t_seg;
   signal plen      : natural range 0 to 2 ** 16;
   signal wr_ok     : std_logic;
   -- The connection takes data.
   signal take : std_logic;
   -- The segment against the connection, a cycle behind: it is from the
   -- host; how far its acknowledgment number is past una_seq, its
   -- sequence number past snd_wl1 and rcv_nxt, and its acknowledgment
   -- number past snd_wl2; the end of its data; whether it acknowledges
   -- the SYN-ACK, and the FIN; and rcv_nxt past its data, with the FIN
   -- and without, and past a FIN alone; and its sequence number past its
   -- data, SYN, and FIN, for a RST
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
   signal seg_end   : std_logic_vector(31 downto 0) := (others => '0');

   -- The receive buffer (eth_tcp_buf.vhd): a segment's data goes in as it
   -- comes; the room for it, after the data written; and the room after
   -- the data committed, the receive window
   signal rx_we   : std_logic;
   signal rx_room : natural range 0 to C_SIZE;
   signal rx_free : natural range 0 to C_SIZE;
   -- The connection's verdict on the segment's data, for the buffer, a
   -- cycle after: it is committed, or discarded
   signal cmt     : std_logic := '0';
   signal discard : std_logic := '0';
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

   seg_ready <= not stale;
   eval      <= seg_valid and seg_ready;

   i_eth_tcp_rx : entity work.eth_tcp_rx
      generic map (
         G_PORT      => G_PORT,
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         mac_i       => mac_i,
         ip_i        => ip_i,
         rx_data_i   => rx_data_i,
         rx_last_i   => rx_last_i,
         rx_valid_i  => rx_valid_i,
         rx_ready_o  => rx_ready_o,
         take_i      => take,
         exp_ip_i    => peer.ip,
         exp_port_i  => peer.tcp_port,
         exp_seq_i   => rcv_nxt,
         free_i      => rx_room,
         we_o        => rx_we,
         seg_valid_o => seg_valid,
         seg_ready_i => seg_ready,
         good_o      => good,
         seg_o       => f_seg,
         wr_ok_o     => wr_ok,
         len_o       => plen
      ); -- i_eth_tcp_rx


   ---------------------------------------------------------------------------
   -- The buffers
   ---------------------------------------------------------------------------

   i_eth_tcp_buf : entity work.eth_tcp_buf
      generic map (
         G_ADDR_BITS => G_ADDR_BITS,
         G_IDLE      => C_IDLE,
         G_FORMAL    => G_FORMAL
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         conn_i      => conn,
         una_ptr_i   => buf_una,
         ltx_data_i  => ltx_data_i,
         ltx_valid_i => ltx_valid_i,
         ltx_ready_o => ltx_ready_o,
         tail_ptr_o  => tail_ptr,
         paused_o    => paused,
         rd_addr_i   => tx_raddr,
         rd_data_o   => tx_rdata,
         wr_we_i     => rx_we,
         wr_data_i   => rx_data_i,
         room_o      => rx_room,
         cmt_i       => cmt,
         discard_i   => discard,
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

   -- The timer runs while there is a connection and the SYN-ACK, data, or
   -- the FIN is out, or a window of 0 holds data back, and not after its
   -- end, whatever was out then; it stands still while a segment is acted
   -- on or the connection ends, which come first. The timer takes it a
   -- cycle later (armed_r), for the timing. That is safe: armed falls only
   -- after a cycle in which a segment was acted on, the connection ended,
   -- or the timer ran out, as all else that it reads only grows or sets it,
   -- and the timer stands still in the cycle after each, so no tick meets
   -- the old value; it rises a cycle late, which delays the first timeout
   -- by a cycle.
   armed <= '1' when syn_rcvd = '1' or
                     (estab = '1' and (max_ptr /= una_ptr or
                                       (state = LAST_ACK_ST and fin_max = '1') or
                                       (snd_wnd = 0 and lim_ptr /= una_ptr))) else
            '0';

   i_eth_tcp_timer : entity work.eth_tcp_timer
      generic map (
         G_TICK   => C_TICK,
         G_RTO_MS => C_RTO_MS,
         G_TRIES  => C_TRIES,
         G_FORMAL => G_FORMAL
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         armed_i     => armed_r,
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
         clk_i      => clk_i,
         rst_i      => rst_i,
         mac_i      => mac_i,
         ip_i       => ip_i,
         syn_rcvd_i => syn_rcvd,
         estab_i    => estab,
         syn_req_i  => syn_req,
         ack_req_i  => ack_req,
         closing_i  => closing,
         fin_sent_i => fin_sent,
         probe_i    => probe,
         drop_i     => drop,
         peer_i     => peer,
         iss_i      => iss,
         una_seq_i  => una_seq,
         rcv_nxt_i  => rcv_nxt,
         snd_wnd_i  => snd_wnd,
         free_i     => rx_free,
         rst_req_i  => rst_req,
         rst_ack_i  => rst_ack,
         rst_host_i => rst_host,
         rst_num_i  => rst_num,
         una_ptr_i  => una_ptr,
         nxt_ptr_i  => nxt_ptr,
         lim_ptr_i  => lim_ptr,
         paused_i   => paused,
         pick_o     => pick,
         pick_n_o   => pick_n,
         adv_wnd_o  => adv_wnd,
         busy_o     => busy,
         rd_addr_o  => tx_raddr,
         rd_data_i  => tx_rdata,
         tx_data_o  => tx_data_o,
         tx_last_o  => tx_last_o,
         tx_valid_o => tx_valid_o,
         tx_ready_i => tx_ready_i
      ); -- i_eth_tcp_pick


   p_cmp : process (clk_i)
   begin
      if rising_edge(clk_i) then
         from_peer <= f_seg.host.ip = peer.ip and f_seg.host.tcp_port = peer.tcp_port;
         k         <= f_seg.ack - una_seq;
         d1        <= f_seg.seq - snd_wl1;
         seq_off   <= f_seg.seq - rcv_nxt;
         d2        <= f_seg.ack - snd_wl2;
         f_end     <= f_seg.seq + plen;
         syn_acked <= f_seg.ack = iss + 1;
         fin_acked <= f_seg.ack = una_seq + (fin_ptr - una_ptr) + 1;
         rcv_end   <= rcv_nxt + plen;
         rcv_end1  <= rcv_nxt + plen + 1;
         rcv_nxt1  <= rcv_nxt + 1;
         seg_end   <= f_seg.seq + plen + f_seg.flags(1) + f_seg.flags(0);
      end if;
   end process p_cmp;


   p_tcp : process (clk_i)
      variable syn_v     : boolean;
      variable fin_v     : boolean;
      variable ack_fin_v : boolean;
      variable cmt_v     : boolean;
      variable next_v    : boolean;

      -- Opens a connection for a SYN; the output after base goes to it.
      procedure accept (
         host : t_host;
         seq  : std_logic_vector(31 downto 0);
         win  : std_logic_vector(15 downto 0);
         base : t_ptr
      ) is
      begin
         state     <= SYN_RCVD_ST;
         peer      <= host;
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
            -- A SYN waits only from the connection's IP address.
            accept((mac => pend_host.mac, ip => peer.ip, tcp_port => pend_host.tcp_port),
                   pend_seq, pend_win, fin_ptr);
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

      -- Asks for a RST to the segment's source, unless it is a RST, or one
      -- waits.
      procedure refuse is
      begin
         if f_seg.flags(2) = '0' and rst_req = '0' then
            rst_req  <= '1';
            rst_ack  <= not f_seg.flags(4);
            rst_host <= f_seg.host;
            if f_seg.flags(4) = '1' then
               rst_num <= f_seg.ack;
            else
               rst_num <= seg_end;
            end if;
         end if;
      end procedure refuse;

   begin
      if rising_edge(clk_i) then
         isn       <= isn + 1;
         armed_r   <= armed;
         stale     <= ending or timeout;
         if busy = '0' then
            buf_una <= una_ptr;
         end if;
         cmt       <= '0';
         discard   <= '0';
         brk_set   <= '0';
         restart   <= '0';
         tries_clr <= '0';

         -- A window that has grown is told.
         if state = EST_ST and rx_free >= adv_wnd + C_WND_STEP then
            ack_req <= '1';
         end if;

         ------------------------------------------------------------------
         -- The segment, in the second cycle after its last byte
         ------------------------------------------------------------------
         if eval = '1' then
            cmt_v := false;

            if good = '1' and ip_i /= 0 then
               syn_v := f_seg.flags(1) = '1' and f_seg.flags(4) = '0' and f_seg.flags(2) = '0';

               if syn_v then

                  case state is

                     when LISTEN_ST =>
                        accept(f_seg.host, f_seg.seq, f_seg.win, tail_ptr);

                     when SYN_RCVD_ST =>
                        -- Another SYN replaces it; the output after its base,
                        -- if the link is kept, goes to the new one.
                        if from_peer and f_seg.seq = irs then
                           syn_req <= '1';
                        else
                           accept(f_seg.host, f_seg.seq, f_seg.win, una_ptr);
                        end if;

                     when EST_ST | CLOSE_WAIT_ST | LAST_ACK_ST =>
                        if from_peer and f_seg.seq = irs then
                           ack_req <= '1';
                        elsif f_seg.host.ip = peer.ip then
                           pend      <= '1';
                           pend_host <= f_seg.host;
                           pend_seq  <= f_seg.seq;
                           pend_win  <= f_seg.win;
                           if closing = '0' then
                              closing <= '1';
                              fin_ptr <= tail_ptr;
                           end if;
                        else
                           -- Another host, while a connection is open
                           refuse;
                        end if;

                  end case;

               elsif from_peer and state /= LISTEN_ST then
                  if f_seg.flags(2) = '1' then
                     -- A reset, with a sequence number in the window
                     if seq_off < C_SIZE then
                        finish;
                     end if;
                  elsif state = SYN_RCVD_ST and not (f_seg.flags(4) = '1' and syn_acked) then
                     -- Nothing but the ACK of the SYN-ACK opens the connection,
                     -- and another ACK gets a RST.
                     if f_seg.flags(4) = '1' then
                        refuse;
                     end if;
                  elsif f_seg.flags(4) = '0' then
                     -- Without ACK, the segment is dropped (RFC 9293
                     -- 3.10.7.4, step 5).
                     null;
                  elsif k(31) = '0' and k > max_ptr - una_ptr and
                        not (fin_max = '1' and fin_acked) then
                     -- An ACK of what was not sent gets an ACK, and the
                     -- segment is dropped; one before una_seq, k(31) = '1',
                     -- is old, and its data is taken.
                     ack_req <= '1';
                  else
                     -- The ACK of the SYN-ACK, which may carry data and a FIN
                     if state = SYN_RCVD_ST then
                        state   <= EST_ST;
                        keep    <= '0';
                        restart <= '1';
                     end if;

                     -- The ACK: the bytes it covers are free, also when it
                     -- covers this side's FIN, one past them, as well.
                     if f_seg.flags(4) = '1' then
                        ack_fin_v := fin_max = '1' and fin_acked;
                        if (k <= max_ptr - una_ptr or ack_fin_v) and
                           ((d1 /= 0 and d1(31) = '0') or (d1 = 0 and d2(31) = '0')) then
                           snd_wnd <= f_seg.win;
                           snd_wl1 <= f_seg.seq;
                           snd_wl2 <= f_seg.ack;
                           if f_seg.win = 0 then
                              tries_clr <= '1';
                           end if;
                        end if;
                        if k /= 0 and k <= max_ptr - una_ptr then
                           una_ptr <= una_ptr + k(G_ADDR_BITS downto 0);
                           una_seq <= f_seg.ack;
                           if k > nxt_ptr - una_ptr then
                              nxt_ptr <= una_ptr + k(G_ADDR_BITS downto 0);
                           end if;
                           restart <= '1';
                        elsif ack_fin_v and max_ptr /= una_ptr then
                           una_ptr <= max_ptr;
                           una_seq <= f_seg.ack - 1;
                           nxt_ptr <= max_ptr;
                           restart <= '1';
                        end if;
                     end if;

                     -- The data, which was written if it was the next, and
                     -- still is: the connection may have ended since, and
                     -- another opened from the same port
                     next_v := wr_ok = '1' and seq_off = 0;
                     -- The host's FIN, if all before it has come: after the
                     -- data written, whose sequence number is rcv_nxt, or
                     -- at rcv_nxt otherwise
                     fin_v := f_seg.flags(0) = '1' and peer_fin = '0' and
                              (next_v or f_end = rcv_nxt);
                     if next_v then
                        cmt_v   := true;
                        rcv_nxt <= rcv_end;
                        if fin_v then
                           rcv_nxt <= rcv_end1;
                        end if;
                     elsif fin_v then
                        rcv_nxt <= rcv_nxt1;
                     end if;
                     -- Data, a FIN, or a segment that is not the next, as a
                     -- keepalive probe at rcv_nxt - 1 is, gets an ACK.
                     if plen > 0 or f_seg.flags(0) = '1' or seq_off /= 0 then
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
                     if state = LAST_ACK_ST and fin_max = '1' and f_seg.flags(4) = '1' and
                        fin_acked then
                        fin_ack <= '1';
                     end if;
                  end if;
               else
                  -- A segment that fits no connection
                  refuse;
               end if;
            end if;

            -- The data written is committed, or discarded, so that the next
            -- segment's goes where this one's went; the buffer has it in
            -- the cycle after, before the next frame's data.
            if cmt_v then
               cmt <= '1';
            else
               discard <= '1';
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
         if pick /= X"00" and pick(2) = '0' then
            ack_req <= '0';
         end if;
         -- The RST
         if pick(2) = '1' then
            rst_req <= '0';
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
            rst_req   <= '0';
            pend      <= '0';
            keep      <= '0';
            peer_fin  <= '0';
            cmt       <= '0';
            discard   <= '0';
            brk_set   <= '0';
            restart   <= '0';
            tries_clr <= '0';
            armed_r   <= '0';
            stale     <= '0';
            buf_una   <= (others => '0');
         end if;
      end if;
   end process p_tcp;


   gen_formal : if G_FORMAL generate
      -- A connection opened at the last edge, by a SYN or one that waited:
      -- only accept leaves restart with the state SYN_RCVD_ST.
      signal f_acc : std_logic;
      -- The segment taken, against the connection as it is, not as p_cmp
      -- has it: it is a SYN; it is good and acted on, from the peer of a
      -- connection, and not a SYN; it is a reset in the window; it is
      -- acted on as an ACK; and its ACK is of what was not sent
      signal f_syn    : std_logic;
      signal f_from   : boolean;
      signal f_peer   : std_logic;
      signal f_rst_in : std_logic;
      signal f_acks   : std_logic;
      signal f_unsent : std_logic;
      signal f_k      : std_logic_vector(31 downto 0);
      signal f_k_ptr  : t_ptr;
      signal f_out    : t_ptr;
      signal f_fin_ok : std_logic;
      signal f_upd    : std_logic;
      -- The segment's fields, for prev()
      signal f_seq : std_logic_vector(31 downto 0);
      signal f_ack : std_logic_vector(31 downto 0);
      signal f_win : std_logic_vector(15 downto 0);
      -- What a segment chosen carries: an ACK
      signal f_pick_ack : std_logic;
      -- una_seq past the SYN, against una_ptr past the base
      signal f_una_off : std_logic_vector(31 downto 0);
      -- The bytes written since the last commit or discard, and those
      -- committed since the connection opened, with the bytes of a
      -- commit in this cycle
      signal f_wr   : natural range 0 to C_SIZE        := 0;
      signal f_rcvd : std_logic_vector(31 downto 0) := (others => '0');
      signal f_rx   : std_logic_vector(31 downto 0);
      -- una_ptr when the connection opened
      signal f_base  : t_ptr                         := (others => '0');
      signal f_base0 : t_ptr;
      -- The connection has had its break.
      signal f_brk : std_logic := '0';
      -- Where the segment being sent starts
      signal f_seg_ptr : t_ptr := (others => '0');
   begin

      f_acc <= syn_rcvd and restart;

      f_seq      <= f_seg.seq;
      f_ack      <= f_seg.ack;
      f_win      <= f_seg.win;
      f_pick_ack <= '1' when pick /= X"00" and pick(2) = '0' else
                    '0';
      f_una_off  <= una_seq - iss - 1;

      f_syn    <= f_seg.flags(1) and not f_seg.flags(4) and not f_seg.flags(2);
      f_from   <= f_seg.host.ip = peer.ip and f_seg.host.tcp_port = peer.tcp_port;
      f_peer   <= '1' when eval = '1' and good = '1' and ip_i /= 0 and f_syn = '0' and f_from and
                           state /= LISTEN_ST else
                  '0';
      f_rst_in <= '1' when f_peer = '1' and f_seg.flags(2) = '1' and
                           f_seg.seq - rcv_nxt < C_SIZE else
                  '0';
      f_k      <= f_seg.ack - una_seq;
      f_k_ptr  <= f_k(G_ADDR_BITS downto 0);
      f_out    <= max_ptr - una_ptr;
      f_fin_ok <= '1' when fin_max = '1' and f_seg.ack = una_seq + (fin_ptr - una_ptr) + 1 else
                  '0';
      f_unsent <= '1' when f_peer = '1' and f_seg.flags(2) = '0' and f_seg.flags(4) = '1' and
                           (syn_rcvd = '0' or f_seg.ack = iss + 1) and
                           f_k(31) = '0' and f_k > f_out and f_fin_ok = '0' else
                  '0';
      f_acks   <= '1' when f_peer = '1' and f_seg.flags(2) = '0' and f_seg.flags(4) = '1' and
                           (syn_rcvd = '0' or f_seg.ack = iss + 1) and f_unsent = '0' else
                  '0';
      -- RFC 9293 3.10.7.4: the window is taken from an ACK of what was
      -- sent that is not older than the last one it was taken from.
      f_upd <= '1' when f_acks = '1' and (f_k <= f_out or f_fin_ok = '1') and
                           ((f_seg.seq - snd_wl1 /= 0 and (f_seg.seq - snd_wl1) < X"80000000") or
                            (f_seg.seq = snd_wl1 and (f_seg.ack - snd_wl2) < X"80000000")) else
                  '0';

      f_rx    <= (f_rcvd and (31 downto 0 => not f_acc)) + f_wr when cmt = '1' else
                 f_rcvd and (31 downto 0 => not f_acc);
      f_base0 <= una_ptr when f_acc = '1' else
                 f_base;

      p_ghost : process (clk_i)
      begin
         if rising_edge(clk_i) then
            f_rcvd <= f_rx;
            f_base <= f_base0;

            if cmt = '1' or discard = '1' then
               f_wr <= 0;
               if rx_we = '1' then
                  f_wr <= 1;
               end if;
            elsif rx_we = '1' then
               f_wr <= f_wr + 1;
            end if;

            if f_acc = '1' then
               f_brk <= '0';
            elsif brk_set = '1' then
               f_brk <= '1';
            end if;

            if pick /= X"00" then
               f_seg_ptr <= nxt_ptr;
            end if;

            if rst_i = '1' then
               f_wr  <= 0;
               f_brk <= '0';
            end if;
         end if;
      end process p_ghost;

      -- psl default clock is rising_edge(clk_i);

      -- The parser's promise, which formal/eth_tcp_rx.sby proves: a good
      -- segment whose data was written has had all of it written. The
      -- free parser of eth_tcp.sby keeps it, but cannot see f_wr.
      -- psl f_parser : assume always eval = '1' and good = '1' and wr_ok = '1' -> f_wr = plen;

      -- psl f_state : assert always state = LISTEN_ST or state = SYN_RCVD_ST or state = EST_ST or
      --    state = CLOSE_WAIT_ST or state = LAST_ACK_ST;

      -- The pointers of the send buffer, in order
      -- psl f_order : assert always nxt_ptr - una_ptr <= max_ptr - una_ptr and
      --    max_ptr - una_ptr <= lim_ptr - una_ptr and lim_ptr - una_ptr <= tail_ptr - una_ptr and
      --    tail_ptr - una_ptr <= C_SIZE;
      -- psl f_buf_una : assert always una_ptr - buf_una <= tail_ptr - buf_una and
      --    tail_ptr - buf_una <= C_SIZE;
      -- psl f_seg_start : assert always busy = '1' ->
      --    f_seg_ptr - buf_una <= tail_ptr - buf_una;
      -- psl f_fin_ptr : assert always fin_max = '1' -> closing = '1' and max_ptr = fin_ptr;
      -- psl f_fin_ack : assert always fin_ack = '1' -> una_ptr = max_ptr;
      -- psl f_fin_ack_st : assert always fin_ack = '1' -> state = LAST_ACK_ST and fin_max = '1';
      -- psl f_syn_fin : assert always syn_rcvd = '1' -> peer_fin = '0';
      -- p_cmp has the segment against the connection as it is, but in the
      -- cycle after the connection ended or the timer ran out.
      -- psl f_cmp : assert always seg_valid = '1' and stale = '0' ->
      --    from_peer = f_from and k = f_k and d1 = f_seg.seq - snd_wl1 and
      --    seq_off = f_seg.seq - rcv_nxt and d2 = f_seg.ack - snd_wl2 and
      --    f_end = f_seg.seq + plen and syn_acked = (f_seg.ack = iss + 1) and
      --    fin_acked = (f_seg.ack = una_seq + (fin_ptr - una_ptr) + 1) and
      --    rcv_end = rcv_nxt + plen and rcv_end1 = rcv_nxt + plen + 1 and
      --    rcv_nxt1 = rcv_nxt + 1 and
      --    seg_end = f_seg.seq + plen + f_seg.flags(1) + f_seg.flags(0);
      -- psl f_pend : assert always pend = '1' -> estab = '1' and closing = '1';
      -- psl f_sent : assert always busy = '1' -> tail_ptr - f_seg_ptr <= C_SIZE;

      -- The connection opens only by the ACK of its SYN-ACK, and the link
      -- goes to it no earlier.
      -- psl f_keep : assert always keep = '1' -> syn_rcvd = '1';
      -- psl f_estab : assert always {estab = '0' and rst_i = '0'} |=>
      --    {estab = '0' or (prev(syn_rcvd) = '1' and prev(f_acks) = '1')};
      -- psl f_conn : assert always {conn = '0' and rst_i = '0'} |=>
      --    {conn = '0' or (prev(syn_rcvd) = '1' and prev(f_acks) = '1')};
      -- psl f_timer : assert always timeout = '1' -> state /= LISTEN_ST;

      -- The data received: rcv_nxt is the host's first number past the
      -- data committed and its FIN, and data is committed only from the
      -- peer, at rcv_nxt.
      -- psl f_rcv_nxt : assert always state /= LISTEN_ST -> rcv_nxt = irs + 1 + f_rx + peer_fin;
      -- psl f_cmt : assert always {eval = '1' and rst_i = '0'} |=>
      --    {cmt = '0' or (prev(f_acks) = '1' and prev(f_seq) = prev(rcv_nxt))};
      -- psl f_ack_req : assert always {((f_acks = '1' and (plen > 0 or f_seg.flags(0) = '1' or
      --    f_seg.seq /= rcv_nxt)) or f_unsent = '1') and rst_i = '0'} |=> {ack_req};
      -- psl f_ack_held : assert always {ack_req = '1' and rst_i = '0'} |=>
      --    {ack_req = '1' or f_acc = '1' or prev(f_pick_ack) = '1'};

      -- The data sent: una_seq is the number of the byte at una_ptr, which
      -- moves only to what an ACK covers.
      -- psl f_una_seq : assert always state /= LISTEN_ST ->
      --    f_una_off(G_ADDR_BITS downto 0) = una_ptr - f_base0;
      -- psl f_una : assert always {rst_i = '0'} |=>
      --    {f_acc = '1' or una_ptr = prev(una_ptr) or
      --     (prev(f_acks) = '1' and
      --      ((prev(f_k) /= 0 and prev(f_k) <= prev(f_out) and una_seq = prev(f_ack) and
      --        una_ptr = prev(una_ptr) + prev(f_k_ptr)) or
      --       (prev(f_fin_ok) = '1' and una_seq = prev(f_ack) - 1 and
      --        una_ptr = prev(max_ptr))))};
      -- psl f_wnd : assert always {rst_i = '0'} |=>
      --    {f_acc = '1' or
      --     (snd_wnd = prev(snd_wnd) and snd_wl1 = prev(snd_wl1) and snd_wl2 = prev(snd_wl2)) or
      --     (prev(f_upd) = '1' and snd_wnd = prev(f_win) and snd_wl1 = prev(f_seq) and
      --      snd_wl2 = prev(f_ack))};

      -- The end: by a reset in the window, the last try, or the ACK of
      -- this side's FIN
      -- psl f_ends : assert always {(syn_rcvd = '1' or estab = '1') and rst_i = '0'} |=>
      --    {(state /= LISTEN_ST and f_acc = '0') or prev(f_rst_in) = '1' or
      --     prev(timeout and last_try) = '1' or prev(ending) = '1' or
      --     (prev(syn_rcvd) = '1' and prev(eval) = '1' and prev(f_syn) = '1')};
      -- psl f_fin_acked : assert always {fin_ack = '0' and rst_i = '0'} |=>
      --    {fin_ack = '0' or (prev(f_acks) = '1' and prev(state) = LAST_ACK_ST and
      --     prev(f_fin_ok) = '1')};

      -- The break: once per connection, as the host's FIN comes, or at
      -- its end without one
      -- psl f_brk_once : assert always brk_set = '1' -> f_brk = '0';
      -- psl f_brk_peer : assert always f_acc = '0' and brk_set = '0' -> f_brk = peer_fin;
      -- psl f_brk_fin : assert always {brk_set = '0' and rst_i = '0'} |=>
      --    {brk_set = '0' or (peer_fin = '1' and prev(peer_fin) = '0') or
      --     (f_acc = '1' and prev(estab) = '1' and prev(peer_fin) = '0')};

      -- Without an IP address, nothing opens, and nothing is sent.
      -- psl f_off : assert always ip_i = 0 -> state = LISTEN_ST and rst_req = '0' and pick = X"00";

      -- The contracts of the timer, the buffers, and the chooser
      -- psl f_timer_pulse : assert always {eval = '0' and ending = '0' and timeout = '0' and
      --    rst_i = '0'} |=> {restart = '0' and tries_clr = '0'};
      -- psl f_room : assert always rx_we = '1' -> rx_room > 0;
      -- psl f_brk_cmt : assert always {brk_set and not rst_i} |=> {not cmt};
      -- psl f_still : assert always {drop = '0' and pick = X"00" and rst_i = '0'} |=>
      --    {nxt_ptr = prev(nxt_ptr) and una_ptr = prev(una_ptr) and una_seq = prev(una_seq) and
      --     snd_wnd = prev(snd_wnd) and rcv_nxt = prev(rcv_nxt) and iss = prev(iss) and
      --     peer.mac = prev(peer.mac) and peer.ip = prev(peer.ip) and
      --     peer.tcp_port = prev(peer.tcp_port) and rst_host.mac = prev(rst_host.mac) and
      --     rst_host.ip = prev(rst_host.ip) and rst_host.tcp_port = prev(rst_host.tcp_port) and
      --     rst_num = prev(rst_num) and
      --     fin_sent = prev(fin_sent) and closing = prev(closing) and probe = prev(probe) and
      --     syn_req = prev(syn_req) and syn_rcvd = prev(syn_rcvd) and estab = prev(estab) and
      --     rst_req = prev(rst_req) and rst_ack = prev(rst_ack) and
      --     lim_ptr - prev(lim_ptr) <= 1};

      -- psl c_syn_rcvd : cover {syn_rcvd = '1' and rst_i = '0'};
      -- psl c_estab : cover {state = EST_ST and rst_i = '0'};
      -- psl c_close_wait : cover {state = CLOSE_WAIT_ST and rst_i = '0'};
      -- psl c_last_ack : cover {state = LAST_ACK_ST and rst_i = '0'};
      -- psl c_closed : cover {fin_ack = '1' and ending = '1' and rst_i = '0'};
      -- psl c_data : cover {cmt = '1' and f_wr = 2 and rst_i = '0'};
      -- psl c_acked : cover {f_acks = '1' and f_k = 2 and rst_i = '0'};
      -- psl c_fin_data : cover {f_acks = '1' and f_fin_ok = '1' and f_out /= 0 and rst_i = '0'};
      -- psl c_replace : cover {f_acc = '1' and prev(estab) = '1' and prev(peer_fin) = '1' and
      --    rst_i = '0'};
      -- psl c_replace_brk : cover {f_acc = '1' and prev(estab) = '1' and brk_set = '1' and
      --    rst_i = '0'};
      -- psl c_probe : cover {pick(3) = '1' and probe = '1' and snd_wnd = 0 and rst_i = '0'};
      -- psl c_tries : cover {timeout = '1' and last_try = '1' and estab = '1' and rst_i = '0'};
      -- psl c_reset : cover {f_rst_in = '1' and estab = '1' and rst_i = '0'};
   end generate gen_formal;

end architecture synthesis;
