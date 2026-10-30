-- Tests the TCP server of the debug link (src/eth/eth_tcp.vhd) at its
-- ports, with a host modeled here.
--
-- THEORY OF OPERATION
-- The clock is 100 MHz, and G_CLOCK_HZ is 100 kHz, so that a millisecond of
-- the server's timers is 100 cycles, and its retransmission timeout of
-- 300 ms is 300 us here. p_host plays the host: it sends frames into
-- rx_*, one byte a cycle, and checks the segments that p_capture keeps
-- from tx_*: their Ethernet, IPv4, and TCP headers, both checksums, which
-- it adds up itself, and their data, which the link side sends as the
-- pattern of byte k = k mod 251. p_lrx keeps the bytes that the link
-- side gets, which must be the host's data, k mod 239 for its byte k,
-- and counts the breaks; p_ltx sends the bytes that p_host asks for.
-- The frames have a gap in rx_valid after every 13th byte, the SYNs
-- carry the options of Linux, and some data segments carry options too.
-- p_probe checks, in every cycle, that the retransmission timer runs only
-- while there is a connection, that an ACK of this side's FIN frees the
-- data before it, as when the ACK covers both at once, that the link's
-- output does not overwrite a segment while it is sent, and that the
-- server keeps the contracts that the formal jobs of its parts assume.
-- With G_RANDOM, the random stage replaces the steps: G_STEPS random
-- actions on one connection, from G_SEED (random_stage in p_host).
-- The steps:
--   * a SYN while the IP address is 0, or to another port, gets nothing
--   * a SYN gets a SYN-ACK, which comes again when the host does not
--     acknowledge it, and the host's ACK opens the connection; the link
--     goes to it only then
--   * data gets an ACK; the same data again, data out of order, and data
--     with a wrong checksum are dropped, and the first two get an ACK, as
--     does a keepalive probe
--   * the link's output comes in segments of at most 536 bytes, at most
--     as many unacknowledged as the host's window takes, and again after
--     the timeout when the host does not acknowledge it
--   * a window of 0 gets a byte beyond it after each timeout, also past
--     the tries, while the host answers, and the window of an older
--     segment is not taken
--   * data that does not fit the receive buffer is dropped, and the window
--     that it frees is told
--   * a frame longer than the server reads overwrites no input
--   * the host's FIN is a break after the data before it, and output still
--     goes to the host after it
--   * a SYN from another port of the host after the FIN closes the old
--     connection with a FIN, which comes again until it is acknowledged,
--     and opens the new one when the host has acknowledged that FIN
--   * an RST ends the connection, and a SYN from another IP address does
--     not replace one; the link keeps it until it has taken the input,
--     and a break waits for the input before it, also when a new
--     connection's input comes after it
--   * a SYN from another port of the host before its FIN closes the old
--     connection with a FIN too; the old one still takes data and the
--     host's FIN, and if that never comes, its end by an RST is a break
--   * data in the host's ACK of the SYN-ACK is taken
--   * a segment that fits no connection gets a RST, with ACK if it has
--     none, and a RST gets nothing: a SYN from another IP address while
--     a connection is open, an ACK from another port, an ACK not of the
--     SYN-ACK, segments while there is no connection, and an ACK of a
--     connection that has ended
--   * an RST while data is out ends the connection, and its timer
--   * a data offset below 5, or an IP total length shorter than the
--     headers, is not good
--   * a SYN with a FIN or data opens a connection for the SYN alone; a
--     partial ACK frees what it covers; a segment with old bytes and new
--     ones is dropped whole; an old ACK and its window are not taken, but
--     its data is; a segment without ACK is dropped; an ACK of what was
--     not sent gets an ACK, and its data is dropped; an RST from another
--     IP address does nothing; a FIN ahead of its data is not taken; and
--     a SYN from the connection's own port replaces it
--   * both sides' sequence numbers wrap around 2^32 in one connection
--   * an RST ends a connection that waits for the ACK of its SYN-ACK
--   * a SYN-ACK that is never acknowledged ends the connection after the
--     tries

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;
   use ieee.math_real.all;

   use std.env.all;

library work;
   use work.eth_pkg.all;

entity tb_eth_tcp is
   generic (
      -- The random stage instead of the steps, with its seed and its
      -- number of actions
      G_RANDOM : boolean  := false;
      G_SEED   : positive := 1;
      G_STEPS  : natural  := 2500
   );
end entity tb_eth_tcp;

architecture simulation of tb_eth_tcp is

   constant C_MAC   : std_logic_vector(47 downto 0) := X"024E49434500";
   constant C_IP    : std_logic_vector(31 downto 0) := X"C0A80141";
   constant C_HMAC  : std_logic_vector(47 downto 0) := X"020000000001";
   constant C_HIP   : std_logic_vector(31 downto 0) := X"C0A80103";
   constant C_HIP2  : std_logic_vector(31 downto 0) := X"C0A80104";
   constant C_PORT  : std_logic_vector(15 downto 0) := X"119E";
   constant C_MSS   : natural                       := 536;
   constant C_RING  : natural                       := 16;
   constant C_FMAX  : natural                       := 620;
   constant C_CYCLE : time                          := 10 ns;
   -- The retransmission timeout, 300 ms of 100 cycles, and its tries
   constant C_RTO   : time                          := 300 * 100 * C_CYCLE;
   constant C_TRIES : natural                       := 17;

   type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

   type t_frame is record
      len : natural;
      b   : t_bytes(0 to C_FMAX - 1);
   end record t_frame;

   type t_ring is array (0 to C_RING - 1) of t_frame;

   signal clk : std_logic;
   signal rst : std_logic                     := '1';
   signal ip  : std_logic_vector(31 downto 0) := C_IP;

   signal rx_data  : std_logic_vector(7 downto 0) := X"00";
   signal rx_last  : std_logic                    := '0';
   signal rx_valid : std_logic                    := '0';
   signal rx_ready : std_logic;
   signal tx_data  : std_logic_vector(7 downto 0);
   signal tx_last  : std_logic;
   signal tx_valid : std_logic;
   signal tx_ready : std_logic                    := '1';

   signal conn      : std_logic;
   signal lrx_data  : std_logic_vector(7 downto 0);
   signal lrx_valid : std_logic;
   signal lrx_ready : std_logic;
   signal lrx_break : std_logic;
   signal lrx_renew : std_logic;
   signal ltx_data  : std_logic_vector(7 downto 0) := X"00";
   signal ltx_valid : std_logic                    := '0';
   signal ltx_ready : std_logic;

   -- The frames sent, the bytes the link got and its breaks, and the bytes
   -- the link is to send and has sent
   signal got     : t_ring;
   signal n_got   : natural   := 0;
   signal n_log   : natural   := 0;
   signal n_break : natural   := 0;
   -- The bytes the link had got at the last break
   signal brk_at : natural   := 0;
   -- The renewals of the line's input, and the bytes the link had got at
   -- the last
   signal n_renew : natural   := 0;
   signal rnw_at  : natural   := 0;
   signal lrx_bad : boolean   := false;
   signal hold    : std_logic := '0';
   signal tx_stop : std_logic := '0';
   signal ltx_req : natural   := 0;
   signal n_ltx   : natural   := 0;
   signal n_fin   : natural   := 0;

   function b2 (v : std_logic_vector(15 downto 0)) return t_bytes is
   begin
      return (v(15 downto 8), v(7 downto 0));
   end function b2;

   function b4 (v : std_logic_vector(31 downto 0)) return t_bytes is
   begin
      return (v(31 downto 24), v(23 downto 16), v(15 downto 8), v(7 downto 0));
   end function b4;

   function b6 (v : std_logic_vector(47 downto 0)) return t_bytes is
   begin
      return b2(v(47 downto 32)) & b4(v(31 downto 0));
   end function b6;

   function ones_add (
      a : std_logic_vector(15 downto 0);
      b : std_logic_vector(15 downto 0)
   ) return std_logic_vector is
      variable s_v : std_logic_vector(16 downto 0);
   begin
      s_v := ('0' & a) + ('0' & b);
      return s_v(15 downto 0) + s_v(16);
   end function ones_add;

   -- The ones' complement sum of bytes first to last of f, and a 0 after an
   -- odd last one
   function ones_sum (
      f     : t_frame;
      first : natural;
      last  : natural
   ) return std_logic_vector is
      variable s_v : std_logic_vector(15 downto 0) := X"0000";
      variable i_v : natural;
   begin
      i_v := first;
      while i_v <= last loop
         if i_v = last then
            s_v := ones_add(s_v, f.b(i_v) & X"00");
         else
            s_v := ones_add(s_v, f.b(i_v) & f.b(i_v + 1));
         end if;
         i_v := i_v + 2;
      end loop;
      return s_v;
   end function ones_sum;

   -- The TCP checksum's sum of a frame: the pseudo header, and the segment
   -- to the end of the IP packet
   function tcp_sum (
      f : t_frame
   ) return std_logic_vector is
      variable len_v : natural;
      variable s_v   : std_logic_vector(15 downto 0);
   begin
      len_v := to_integer(f.b(16) & f.b(17)) - 20;
      s_v   := ones_sum(f, 26, 33);
      s_v   := ones_add(s_v, X"0006");
      s_v   := ones_add(s_v, to_stdlogicvector(len_v, 16));
      return ones_add(s_v, ones_sum(f, 34, 33 + len_v));
   end function tcp_sum;

   -- The TCP options of a SYN from Linux: the MSS, SACK permitted, a
   -- timestamp, a NOP, and the window scale
   constant C_OPTS : t_bytes(0 to 19) := (X"02", X"04", X"05", X"B4", X"04", X"02", X"08", X"0A",
      X"12", X"34", X"56", X"78", X"00", X"00", X"00", X"00",
      X"01", X"03", X"03", X"07");

   -- A segment from the host, with opts words of the options of C_OPTS,
   -- and n bytes of data, byte i of which is (d + i) mod 239, padded to 60
   -- bytes as Ethernet has it
   function seg (
      sip   : std_logic_vector(31 downto 0);
      dport : std_logic_vector(15 downto 0);
      sport : natural;
      seq   : std_logic_vector(31 downto 0);
      ack   : std_logic_vector(31 downto 0);
      flags : std_logic_vector(7 downto 0);
      win   : natural;
      n     : natural;
      d     : natural;
      bad   : boolean;
      dip   : std_logic_vector(31 downto 0) := C_IP;
      opts  : natural range 0 to 5          := 0
   ) return t_frame is
      variable f_v : t_frame;
      variable s_v : std_logic_vector(15 downto 0);
      variable h_v : natural;
      variable o_v : std_logic_vector(7 downto 0);
   begin
      h_v                  := 4 * opts;
      o_v                  := to_stdlogicvector(5 + opts, 4) & "0000";
      f_v.b                := (others => X"00");
      f_v.len              := 54 + h_v + n;
      f_v.b(0 to 13)       := b6(C_MAC) & b6(C_HMAC) & t_bytes'(X"08", X"00");
      f_v.b(14 to 33)      := t_bytes'(X"45", X"00") & b2(to_stdlogicvector(40 + h_v + n, 16)) &
                              t_bytes'(X"12", X"34", X"40", X"00", X"40", X"06", X"00", X"00") &
                              b4(sip) & b4(dip);
      f_v.b(34 to 53)      := b2(to_stdlogicvector(sport, 16)) & b2(dport) & b4(seq) & b4(ack) &
                              t_bytes'(o_v, flags) &
                              b2(to_stdlogicvector(win, 16)) & t_bytes'(X"00", X"00", X"00", X"00");
      for i in 0 to h_v - 1 loop
         f_v.b(54 + i) := C_OPTS(i);
      end loop;
      for i in 0 to n - 1 loop
         f_v.b(54 + h_v + i) := to_stdlogicvector((d + i) mod 239, 8);
      end loop;
      s_v             := not ones_sum(f_v, 14, 33);
      f_v.b(24 to 25) := b2(s_v);
      s_v             := not tcp_sum(f_v);
      if bad then
         s_v := s_v + 1;
      end if;
      f_v.b(50 to 51) := b2(s_v);
      if f_v.len < 60 then
         f_v.len := 60;
      end if;
      return f_v;
   end function seg;

   -- The frame f with both checksums made right again, after a change
   function resum (
      f : t_frame
   ) return t_frame is
      variable f_v : t_frame;
   begin
      f_v             := f;
      f_v.b(24 to 25) := X"00" & X"00";
      f_v.b(24 to 25) := b2(not ones_sum(f_v, 14, 33));
      f_v.b(50 to 51) := X"00" & X"00";
      f_v.b(50 to 51) := b2(not tcp_sum(f_v));
      return f_v;
   end function resum;

   -- The flags
   constant C_FIN : std_logic_vector(7 downto 0) := X"01";
   constant C_SYN : std_logic_vector(7 downto 0) := X"02";
   constant C_RST : std_logic_vector(7 downto 0) := X"04";
   constant C_ACK : std_logic_vector(7 downto 0) := X"10";

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_CYCLE / 2;
      wait for C_CYCLE;
   end process p_clk;


   i_eth_tcp : entity work.eth_tcp
      generic map (
         G_CLOCK_HZ => 100_000
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         mac_i       => C_MAC,
         ip_i        => ip,
         rx_data_i   => rx_data,
         rx_last_i   => rx_last,
         rx_valid_i  => rx_valid,
         rx_ready_o  => rx_ready,
         tx_data_o   => tx_data,
         tx_last_o   => tx_last,
         tx_valid_o  => tx_valid,
         tx_ready_i  => tx_ready,
         on_o        => conn,
         lrx_data_o  => lrx_data,
         lrx_valid_o => lrx_valid,
         lrx_ready_i => lrx_ready,
         lrx_break_o => lrx_break,
         lrx_renew_o => lrx_renew,
         ltx_data_i  => ltx_data,
         ltx_valid_i => ltx_valid,
         ltx_ready_o => ltx_ready
      ); -- i_eth_tcp


   -- The frames that the server sends, kept in a ring; tx_ready from a
   -- counter, so that it is sometimes low
   p_capture : process (clk)
      variable f_v : t_frame;
      variable n_v : natural := 0;
      variable c_v : natural := 0;
   begin
      if rising_edge(clk) then
         c_v      := (c_v + 1) mod 7;
         tx_ready <= '0' when c_v = 3 or tx_stop = '1' else
                     '1';
         if tx_valid = '1' and tx_ready = '1' then
            assert n_v < C_FMAX
               report "tb_eth_tcp: FAIL, a frame that is too long"
               severity failure;
            f_v.b(n_v) := tx_data;
            n_v        := n_v + 1;
            if tx_last = '1' then
               f_v.len           := n_v;
               got(n_got mod C_RING) <= f_v;
               n_got             <= n_got + 1;
               n_v               := 0;
            end if;
         end if;
      end if;
   end process p_capture;


   -- The bytes that the link side gets, and its breaks
   lrx_ready <= not hold;

   p_lrx : process (clk)
   begin
      if rising_edge(clk) then
         if lrx_valid = '1' and lrx_ready = '1' then
            if lrx_data /= to_stdlogicvector(n_log mod 239, 8) then
               lrx_bad <= true;
            end if;
            n_log <= n_log + 1;
         end if;
         if lrx_break = '1' then
            n_break <= n_break + 1;
            brk_at  <= n_log;
         end if;
         if lrx_renew = '1' then
            n_renew <= n_renew + 1;
            rnw_at  <= n_log;
         end if;
      end if;
   end process p_lrx;


   -- The bytes that the link side sends, k mod 251 for byte k
   p_ltx : process (clk)
   begin
      if rising_edge(clk) then
         if ltx_valid = '1' and ltx_ready = '1' then
            n_ltx     <= n_ltx + 1;
            ltx_valid <= '0';
            if n_ltx + 1 < ltx_req then
               ltx_data  <= to_stdlogicvector((n_ltx + 1) mod 251, 8);
               ltx_valid <= '1';
            end if;
         elsif ltx_valid = '0' and n_ltx < ltx_req then
            ltx_data  <= to_stdlogicvector(n_ltx mod 251, 8);
            ltx_valid <= '1';
         end if;
      end if;
   end process p_ltx;


   -- A probe of the connection: the retransmission timer runs only while
   -- there is one, and an ACK of this side's FIN, which ends it, frees the
   -- data before the FIN too. It also checks, in the assembled server, the
   -- contracts that the proofs of the timer, the buffers, and the chooser
   -- assume (formal/formal_eth_tcp_*.vhd).
   p_probe : process (clk)
      alias armed     is << signal .tb_eth_tcp.i_eth_tcp.armed : std_logic >>;
      alias syn_rcvd  is << signal .tb_eth_tcp.i_eth_tcp.syn_rcvd : std_logic >>;
      alias estab     is << signal .tb_eth_tcp.i_eth_tcp.estab : std_logic >>;
      alias fin_ack   is << signal .tb_eth_tcp.i_eth_tcp.fin_ack : std_logic >>;
      alias una_ptr   is << signal .tb_eth_tcp.i_eth_tcp.una_ptr : std_logic_vector >>;
      alias max_ptr   is << signal .tb_eth_tcp.i_eth_tcp.max_ptr : std_logic_vector >>;
      alias eval      is << signal .tb_eth_tcp.i_eth_tcp.eval : std_logic >>;
      alias ending    is << signal .tb_eth_tcp.i_eth_tcp.ending : std_logic >>;
      alias timeout   is << signal .tb_eth_tcp.i_eth_tcp.timeout : std_logic >>;
      alias restart   is << signal .tb_eth_tcp.i_eth_tcp.restart : std_logic >>;
      alias tries_clr is << signal .tb_eth_tcp.i_eth_tcp.tries_clr : std_logic >>;
      alias rx_we     is << signal .tb_eth_tcp.i_eth_tcp.rx_we : std_logic >>;
      alias rx_room   is << signal .tb_eth_tcp.i_eth_tcp.rx_room : natural range 0 to 2048 >>;
      alias rx_free   is << signal .tb_eth_tcp.i_eth_tcp.rx_free : natural range 0 to 2048 >>;
      alias cmt       is << signal .tb_eth_tcp.i_eth_tcp.cmt : std_logic >>;
      alias brk_set   is << signal .tb_eth_tcp.i_eth_tcp.brk_set : std_logic >>;
      alias tail_ptr  is << signal .tb_eth_tcp.i_eth_tcp.tail_ptr : std_logic_vector >>;
      alias nxt_ptr   is << signal .tb_eth_tcp.i_eth_tcp.nxt_ptr : std_logic_vector >>;
      alias lim_ptr   is << signal .tb_eth_tcp.i_eth_tcp.lim_ptr : std_logic_vector >>;
      alias drop      is << signal .tb_eth_tcp.i_eth_tcp.drop : std_logic >>;
      alias pick      is << signal .tb_eth_tcp.i_eth_tcp.pick : std_logic_vector >>;
      alias peer      is << signal .tb_eth_tcp.i_eth_tcp.peer : t_host >>;
      alias rst_host  is << signal .tb_eth_tcp.i_eth_tcp.rst_host : t_host >>;
      alias iss       is << signal .tb_eth_tcp.i_eth_tcp.iss : std_logic_vector >>;
      alias una_seq   is << signal .tb_eth_tcp.i_eth_tcp.una_seq : std_logic_vector >>;
      alias rcv_nxt   is << signal .tb_eth_tcp.i_eth_tcp.rcv_nxt : std_logic_vector >>;
      alias snd_wnd   is << signal .tb_eth_tcp.i_eth_tcp.snd_wnd : std_logic_vector >>;
      alias rst_num   is << signal .tb_eth_tcp.i_eth_tcp.rst_num : std_logic_vector >>;
      alias fin_sent  is << signal .tb_eth_tcp.i_eth_tcp.fin_sent : std_logic >>;
      alias closing   is << signal .tb_eth_tcp.i_eth_tcp.closing : std_logic >>;
      alias probe     is << signal .tb_eth_tcp.i_eth_tcp.probe : std_logic >>;
      alias syn_req   is << signal .tb_eth_tcp.i_eth_tcp.syn_req : std_logic >>;
      alias rst_req   is << signal .tb_eth_tcp.i_eth_tcp.rst_req : std_logic >>;
      alias rst_ack   is << signal .tb_eth_tcp.i_eth_tcp.rst_ack : std_logic >>;
      alias busy      is << signal .tb_eth_tcp.i_eth_tcp.busy : std_logic >>;
      alias seg_ptr   is << signal .tb_eth_tcp.i_eth_tcp.i_eth_tcp_pick.seg_ptr : std_logic_vector >>;

      -- The numbers that the chooser takes, which change only at a drop or
      -- a pick
      impure function numbers return std_logic_vector is
      begin
         return nxt_ptr & una_ptr & una_seq & snd_wnd & rcv_nxt & iss &
                peer.mac & peer.ip & peer.tcp_port &
                rst_host.mac & rst_host.ip & rst_host.tcp_port & rst_num &
                fin_sent & closing & probe & syn_req & syn_rcvd & estab &
                rst_req & rst_ack;
      end function numbers;

      constant C_SIZE : natural := 2 ** (una_ptr'length - 1);
      -- The width of numbers: two pointers, the four numbers, two hosts,
      -- rst_num, and eight flags
      constant C_NUMS : natural := 2 * una_ptr'length + 112 + 2 * 96 + 32 + 8;

      variable first_v : boolean := true;
      variable quiet_v : boolean;
      variable still_v : boolean;
      variable rst_v   : std_logic;
      variable lim_v   : std_logic_vector(una_ptr'range);
      variable nums_v  : std_logic_vector(C_NUMS - 1 downto 0);
   begin
      if rising_edge(clk) then
         assert armed = '0' or syn_rcvd = '1' or estab = '1'
            report "tb_eth_tcp: FAIL, the timer runs without a connection"
            severity failure;
         if fin_ack = '1' then
            assert una_ptr = max_ptr
               report "tb_eth_tcp: FAIL, the ACK of the FIN did not free the data"
               severity failure;
            n_fin <= n_fin + 1;
         end if;

         if not first_v and rst_v = '0' then
            -- The timer's: restart and tries_clr only after a hold or a
            -- timeout
            assert not quiet_v or (restart = '0' and tries_clr = '0')
               report "tb_eth_tcp: FAIL, the timer restarted without a hold or a timeout"
               severity failure;
            -- The chooser's: the numbers change only at a drop or a pick
            assert not still_v or (numbers = nums_v and to_integer(lim_ptr - lim_v) <= 1)
               report "tb_eth_tcp: FAIL, the chooser's numbers changed without a drop or a pick"
               severity failure;
         end if;
         if rst = '0' then
            -- The buffers': a write only while there is room, the break no
            -- earlier than the commit of the data before it, and at most a
            -- buffer of output past una_ptr
            assert rx_we = '0' or rx_room > 0
               report "tb_eth_tcp: FAIL, a write beyond the room"
               severity failure;
            assert brk_set = '0' or cmt = '1' or rx_room = rx_free
               report "tb_eth_tcp: FAIL, a break before the commit of the data before it"
               severity failure;
            assert to_integer(tail_ptr - una_ptr) <= C_SIZE
               report "tb_eth_tcp: FAIL, more output than the buffer"
               severity failure;
            -- The link's output does not overwrite the segment being sent.
            assert busy = '0' or ltx_valid = '0' or ltx_ready = '0' or
                   to_integer(tail_ptr - seg_ptr) < C_SIZE
               report "tb_eth_tcp: FAIL, output over the segment being sent"
               severity failure;
            -- The chooser's: the pointers in order
            assert to_integer(nxt_ptr - una_ptr) <= to_integer(lim_ptr - una_ptr) and
                   to_integer(lim_ptr - una_ptr) <= C_SIZE
               report "tb_eth_tcp: FAIL, the chooser's pointers out of order"
               severity failure;
         end if;

         first_v := false;
         rst_v   := rst;
         quiet_v := eval = '0' and ending = '0' and timeout = '0';
         still_v := drop = '0' and pick = X"00";
         lim_v   := lim_ptr;
         nums_v  := numbers;
      end if;
   end process p_probe;


   -- The steps of the test, one after another, are long by nature.
   -- vsg_off length_003
   p_host : process
      -- The frames taken from the ring
      variable n_seen_v : natural := 0;
      -- What the host knows of the connection: the next sequence number of
      -- each side, and the next byte of each stream
      variable sport_v : natural;
      variable hseq_v  : std_logic_vector(31 downto 0);
      variable bseq_v  : std_logic_vector(31 downto 0);
      variable hd_v    : natural := 0;
      variable bd_v    : natural := 0;
      -- The fields of the last segment taken
      variable seq_v   : std_logic_vector(31 downto 0);
      variable ack_v   : std_logic_vector(31 downto 0);
      variable flags_v : std_logic_vector(7 downto 0);
      variable win_v   : natural;
      variable n_v     : natural;
      variable total_v : natural;
      variable f_v     : t_frame;
      variable old_v   : std_logic_vector(31 downto 0);
      variable nb_v    : natural;
      variable nr_v    : natural;
      -- The seeds of the random stage
      variable s1_v : positive := G_SEED;
      variable s2_v : positive := 4510;
      -- The server's initial sequence number, a cycle counter, which a
      -- step sets near 2^32
      alias isn is << signal .tb_eth_tcp.i_eth_tcp.isn : std_logic_vector >>;

      -- With a gap in rx_valid after every 13th byte, as from a FIFO
      procedure send (
         f : t_frame
      ) is
      begin
         -- Drive after an edge, not at the time of one
         wait until rising_edge(clk);
         for i in 0 to f.len - 1 loop
            rx_data  <= f.b(i);
            rx_last  <= '1' when i = f.len - 1 else '0';
            rx_valid <= '1';
            wait until rising_edge(clk) and rx_ready = '1';
            if i mod 13 = 12 then
               rx_valid <= '0';
               rx_data  <= X"FF";
               wait until rising_edge(clk);
            end if;
         end loop;
         rx_valid <= '0';
         rx_last  <= '0';
         wait until rising_edge(clk);
      end procedure send;

      -- A frame of len bytes, f and then zeros, whose IP length is ip_len
      procedure send_long (
         f      : t_frame;
         len    : natural;
         ip_len : natural
      ) is
         variable g_v : t_frame;
      begin
         g_v             := f;
         g_v.b(16 to 17) := b2(to_stdlogicvector(ip_len, 16));
         wait until rising_edge(clk);
         for i in 0 to len - 1 loop
            if i < f.len then
               rx_data <= g_v.b(i);
            else
               rx_data <= X"00";
            end if;
            rx_last  <= '1' when i = len - 1 else '0';
            rx_valid <= '1';
            wait until rising_edge(clk) and rx_ready = '1';
         end loop;
         rx_valid <= '0';
         rx_last  <= '0';
         wait until rising_edge(clk);
      end procedure send_long;

      -- A segment from the host on its connection
      procedure send_seg (
         flags : std_logic_vector(7 downto 0);
         n     : natural;
         win   : natural              := 8192;
         bad   : boolean              := false;
         opts  : natural range 0 to 5 := 0
      ) is
      begin
         send(seg(C_HIP, C_PORT, sport_v, hseq_v, bseq_v, flags, win, n, hd_v, bad, C_IP, opts));
      end procedure send_seg;

      -- Waits for the next segment, at most t, checks it, and takes its
      -- fields; with dport, it is to that port of the host.
      procedure expect (
         t     : time                          := 1 ms;
         dport : natural                       := 0;
         dip   : std_logic_vector(31 downto 0) := C_HIP
      ) is
      begin
         if n_got = n_seen_v then
            wait until n_got > n_seen_v for t;
         end if;
         assert n_got > n_seen_v
            report "tb_eth_tcp: FAIL, no segment"
            severity failure;
         assert n_got - n_seen_v < C_RING
            report "tb_eth_tcp: FAIL, the ring overflowed"
            severity failure;
         f_v      := got(n_seen_v mod C_RING);
         n_seen_v := n_seen_v + 1;

         assert f_v.len >= 54 and f_v.b(0 to 13) = b6(C_HMAC) & b6(C_MAC) & t_bytes'(X"08", X"00")
            report "tb_eth_tcp: FAIL, a wrong Ethernet header"
            severity failure;
         assert f_v.b(14) = X"45" and to_integer(f_v.b(16) & f_v.b(17)) = f_v.len - 14 and
                f_v.b(23) = X"06" and f_v.b(26 to 33) = b4(C_IP) & b4(dip)
            report "tb_eth_tcp: FAIL, a wrong IP header"
            severity failure;
         assert ones_sum(f_v, 14, 33) = X"FFFF"
            report "tb_eth_tcp: FAIL, a wrong IP header checksum"
            severity failure;
         assert tcp_sum(f_v) = X"FFFF"
            report "tb_eth_tcp: FAIL, a wrong TCP checksum"
            severity failure;
         assert f_v.b(34 to 35) = b2(C_PORT) and f_v.b(46) = X"50"
            report "tb_eth_tcp: FAIL, a wrong TCP header"
            severity failure;
         if dport /= 0 then
            assert to_integer(f_v.b(36) & f_v.b(37)) = dport
               report "tb_eth_tcp: FAIL, a segment to another port"
               severity failure;
         end if;
         seq_v   := f_v.b(38) & f_v.b(39) & f_v.b(40) & f_v.b(41);
         ack_v   := f_v.b(42) & f_v.b(43) & f_v.b(44) & f_v.b(45);
         flags_v := f_v.b(47);
         win_v   := to_integer(f_v.b(48) & f_v.b(49));
         n_v     := f_v.len - 54;
      end procedure expect;

      -- Expects an ACK of everything the host has sent, and no data
      procedure expect_ack (
         t : time := 1 ms
      ) is
      begin
         expect(t, sport_v);
         assert flags_v = C_ACK and n_v = 0 and seq_v = bseq_v and ack_v = hseq_v
            report "tb_eth_tcp: FAIL, not the ACK expected"
            severity failure;
      end procedure expect_ack;

      -- Expects data that follows what came before, and takes it, after any
      -- window updates
      procedure expect_data (
         t : time := 1 ms
      ) is
      begin
         expect(t, sport_v);
         -- A window update may come first.
         while flags_v = C_ACK and n_v = 0 and seq_v = bseq_v and ack_v = hseq_v loop
            expect(t, sport_v);
         end loop;
         assert flags_v = X"18" and n_v > 0 and n_v <= C_MSS and seq_v = bseq_v and
                ack_v = hseq_v
            report "tb_eth_tcp: FAIL, not the data expected"
            severity failure;
         for i in 0 to n_v - 1 loop
            assert f_v.b(54 + i) = to_stdlogicvector((bd_v + i) mod 251, 8)
               report "tb_eth_tcp: FAIL, wrong data"
               severity failure;
         end loop;
         bseq_v := bseq_v + n_v;
         bd_v   := bd_v + n_v;
      end procedure expect_data;

      procedure expect_none (
         t : time := 1 ms
      ) is
      begin
         wait for t;
         assert n_got = n_seen_v
            report "tb_eth_tcp: FAIL, a segment that should not come"
            severity failure;
      end procedure expect_none;

      -- Opens a connection from sport, with the host's sequence numbers
      -- from seq
      procedure open_conn (
         sport : natural;
         seq   : std_logic_vector(31 downto 0)
      ) is
      begin
         sport_v := sport;
         hseq_v  := seq;
         send(seg(C_HIP, C_PORT, sport, seq, X"00000000", C_SYN, 8192, 0, 0, false, C_IP, 5));
         expect(1 ms, sport);
         assert flags_v = X"12" and ack_v = seq + 1 and n_v = 0
            report "tb_eth_tcp: FAIL, not a SYN-ACK"
            severity failure;
         hseq_v := seq + 1;
         bseq_v := seq_v + 1;
         send_seg(C_ACK, 0);
      end procedure open_conn;

      -- Sends n bytes of data, and expects their ACK
      procedure send_data (
         n    : natural;
         opts : natural range 0 to 5 := 0
      ) is
      begin
         send_seg(C_ACK, n, opts => opts);
         hseq_v := hseq_v + n;
         hd_v   := hd_v + n;
         expect_ack;
      end procedure send_data;

      -- The link sends n bytes, and they come in segments, which the host
      -- acknowledges as they come
      procedure link_out (
         n : natural
      ) is
      begin
         ltx_req <= ltx_req + n;
         total_v := 0;
         while total_v < n loop
            expect_data;
            total_v := total_v + n_v;
            send_seg(C_ACK, 0);
         end loop;
         assert total_v = n
            report "tb_eth_tcp: FAIL, too much data"
            severity failure;
      end procedure link_out;

      -- A random natural below n
      procedure random (
         n : natural;
         r : out natural
      ) is
         variable x_v : real;
      begin
         uniform(s1_v, s2_v, x_v);
         r := integer(floor(x_v * real(n)));
         if r >= n then
            r := n - 1;
         end if;
      end procedure random;

      -- The random stage: one connection, with sequence numbers across
      -- 2^32, and G_STEPS random actions of the host and the link side.
      -- The host's data is at its stream offset, so a segment sent again
      -- or overlapping carries the right bytes. The host checks every
      -- segment: its ACK is of no more than the host has sent, and never
      -- goes back; its data is the link side's at its offset, only what
      -- the link side has given, and within the host's right edge, but
      -- for a probe of one byte. The host never moves its right edge back.
      -- At the end, everything sent each way arrives, in order, once.
      procedure random_stage is
         -- The host's stream: its base, the end of what it has sent, and
         -- what the server has acknowledged
         variable hbase_v : std_logic_vector(31 downto 0);
         variable hmax_v  : natural := 0;
         variable hack_v  : natural := 0;
         -- The server's stream: its base, the end of what has come in
         -- order, what the host has acknowledged, and its right edge
         variable bbase_v : std_logic_vector(31 downto 0);
         variable brcv_v  : natural := 0;
         variable back_v  : natural := 0;
         variable redge_v : natural := 0;
         variable r_v     : natural;
         variable a_v     : natural;
         variable o_v     : natural;
         variable len_v   : natural;
         variable win_r   : natural;
         variable opts_v  : natural;
         variable d_v     : std_logic_vector(31 downto 0);
         variable n_try_v : natural;

         -- Takes the segments that came, and checks them
         procedure drain is
         begin
            while n_got > n_seen_v loop
               expect(0 ns, 40300);
               assert (flags_v = C_ACK and n_v = 0) or (flags_v = X"18" and n_v > 0)
                  report "tb_eth_tcp: FAIL, random: flags " & to_hstring(flags_v)
                  severity failure;
               d_v := ack_v - hbase_v;
               assert d_v(31) = '0' and to_integer(d_v) <= hmax_v and to_integer(d_v) >= hack_v
                  report "tb_eth_tcp: FAIL, random: an ACK of what was not sent, or back"
                  severity failure;
               hack_v := to_integer(d_v);
               if n_v > 0 then
                  d_v := seq_v - bbase_v;
                  assert d_v(31) = '0'
                     report "tb_eth_tcp: FAIL, random: data before the stream"
                     severity failure;
                  o_v := to_integer(d_v);
                  assert o_v + n_v <= n_ltx
                     report "tb_eth_tcp: FAIL, random: data that the link side did not give"
                     severity failure;
                  assert o_v + n_v <= redge_v + 1
                     report "tb_eth_tcp: FAIL, random: data beyond the host's window"
                     severity failure;
                  for i in 0 to n_v - 1 loop
                     assert f_v.b(54 + i) = to_stdlogicvector((o_v + i) mod 251, 8)
                        report "tb_eth_tcp: FAIL, random: wrong data"
                        severity failure;
                  end loop;
                  if o_v <= brcv_v and o_v + n_v > brcv_v then
                     brcv_v := o_v + n_v;
                  end if;
               end if;
            end loop;
            assert conn = '1'
               report "tb_eth_tcp: FAIL, random: the connection ended"
               severity failure;
         end procedure drain;

         -- Waits for t, taking the segments as they come
         procedure pause (
            t : time
         ) is
            variable w_v : time;
         begin
            w_v := 0 ns;
            while w_v < t loop
               wait for 2 us;
               w_v := w_v + 2 us;
               drain;
            end loop;
         end procedure pause;

         -- The window of a segment of the host, which keeps its right edge
         procedure window (
            w : out natural
         ) is
            variable w_v : natural;
         begin
            random(10, r_v);
            if r_v = 0 then
               w_v := 0;
            elsif r_v < 4 then
               random(1000, w_v);
               w_v := w_v + 1;
            else
               w_v := 8192;
            end if;
            if back_v + w_v < redge_v then
               w_v := redge_v - back_v;
            end if;
            redge_v := back_v + w_v;
            w       := w_v;
         end procedure window;

         -- A segment of the host's stream from offset o, of n bytes
         procedure host_seg (
            o    : natural;
            n    : natural;
            bad  : boolean;
            opts : natural
         ) is
         begin
            window(win_r);
            send(seg(C_HIP, C_PORT, 40300, hbase_v + o, bbase_v + back_v, C_ACK, win_r, n, o,
                     bad, C_IP, opts));
            if not bad and o + n > hmax_v then
               hmax_v := o + n;
            end if;
         end procedure host_seg;

      begin
         -- Both sides' sequence numbers start below 2^32, the host's within
         -- 4K of it, and the server's within 64K, as more goes out.
         random(65536, r_v);
         wait until rising_edge(clk);
         isn <= force X"FFFF0000" + r_v;
         wait until rising_edge(clk);
         isn <= release;
         random(4096, r_v);
         open_conn(40300, X"FFFFF000" + r_v);
         hbase_v := hseq_v;
         bbase_v := bseq_v;
         redge_v := 8192;
         if conn = '0' then
            wait until conn = '1' for 10 us;
         end if;

         for step in 1 to G_STEPS loop
            random(100, a_v);
            if a_v < 35 then
               -- Data, from before what was acknowledged to past what was
               -- sent, sometimes with options or a wrong checksum
               random(201, r_v);
               if r_v > hack_v then
                  r_v := hack_v;
               end if;
               o_v := hack_v - r_v;
               random(hmax_v - o_v + 601, r_v);
               o_v := o_v + r_v;
               random(C_MSS + 1, len_v);
               random(5, opts_v);
               if opts_v > 3 then
                  opts_v := 0;
               end if;
               random(20, r_v);
               host_seg(o_v, len_v, r_v = 0, opts_v);
            elsif a_v < 60 then
               -- An ACK, mostly of all that has come in order
               random(4, r_v);
               if r_v = 0 then
                  random(brcv_v - back_v + 1, r_v);
                  back_v := back_v + r_v;
               else
                  back_v := brcv_v;
               end if;
               host_seg(hack_v, 0, false, 0);
            elsif a_v < 75 then
               -- Output of the link side
               random(1500, r_v);
               ltx_req <= ltx_req + r_v;
            elsif a_v < 80 then
               -- The link side stops or starts taking input.
               random(3, r_v);
               if r_v = 0 and hold = '0' then
                  hold <= '1';
               else
                  hold <= '0';
               end if;
            elsif a_v < 84 then
               -- The host takes no frames for a while.
               random(100, r_v);
               tx_stop <= '1';
               wait for r_v * 1 us;
               tx_stop <= '0';
            elsif a_v < 85 then
               -- A wait long enough for a timeout
               random(2 * C_RTO / 1 us, r_v);
               pause(r_v * 1 us);
            else
               random(50, r_v);
               pause(r_v * 1 us + 1 us);
            end if;
            drain;
         end loop;

         -- The end: the host sends what is missing and acknowledges all,
         -- until everything sent each way has come.
         hold    <= '0';
         tx_stop <= '0';
         n_try_v := 0;
         while not (hack_v = hmax_v and n_log = hmax_v and brcv_v = ltx_req and
                    n_ltx = ltx_req) loop
            assert n_try_v < 2000
               report "tb_eth_tcp: FAIL, random: the streams did not finish"
               severity failure;
            n_try_v := n_try_v + 1;
            back_v  := brcv_v;
            len_v   := hmax_v - hack_v;
            if len_v > C_MSS then
               len_v := C_MSS;
            end if;
            host_seg(hack_v, len_v, false, 0);
            pause(20 us);
         end loop;
         assert not lrx_bad and n_break = 0 and n_renew = 1
            report "tb_eth_tcp: FAIL, random: the link got wrong bytes, a break, or not one renewal"
            severity failure;
         report "tb_eth_tcp: PASS, random, seed " & integer'image(G_SEED) & ", " &
                integer'image(hmax_v) & " bytes in and " & integer'image(brcv_v) & " out, " &
                integer'image(n_got) & " segments";
         finish;
      end procedure random_stage;

   begin
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';
      wait for 100 ns;
      if G_RANDOM then
         random_stage;
      end if;

      -- Nothing while the IP address is 0, and nothing to another port
      ip <= X"00000000";
      wait until rising_edge(clk);
      send(seg(C_HIP, C_PORT, 40000, X"00001000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect_none;
      send(seg(C_HIP, C_PORT, 40000, X"00001000", X"00000000", C_SYN, 8192, 0, 0, false,
               X"00000000"));
      expect_none;
      ip <= C_IP;
      wait until rising_edge(clk);
      send(seg(C_HIP, X"119F", 40000, X"00001000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect_none;
      assert conn = '0'
         report "tb_eth_tcp: FAIL, a connection without one"
         severity failure;

      -- A SYN-ACK comes again until the host acknowledges it.
      sport_v := 40000;
      send(seg(C_HIP, C_PORT, 40000, X"FFFFF000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect(1 ms, 40000);
      assert flags_v = X"12" and ack_v = X"FFFFF001"
         report "tb_eth_tcp: FAIL, not a SYN-ACK"
         severity failure;
      bseq_v := seq_v;
      -- The SYN again gets the same SYN-ACK again.
      send(seg(C_HIP, C_PORT, 40000, X"FFFFF000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect(1 ms, 40000);
      assert flags_v = X"12" and seq_v = bseq_v and ack_v = X"FFFFF001"
         report "tb_eth_tcp: FAIL, not the same SYN-ACK again"
         severity failure;
      -- An ACK of something else is not the host's, and gets a RST at its
      -- acknowledgment number.
      send(seg(C_HIP, C_PORT, 40000, X"FFFFF001", seq_v + 5, C_ACK, 8192, 0, 0, false));
      expect(1 ms, 40000);
      assert flags_v = C_RST and seq_v = bseq_v + 5 and n_v = 0
         report "tb_eth_tcp: FAIL, no RST for an ACK of something else"
         severity failure;
      expect(2 * C_RTO, 40000);
      assert flags_v = X"12" and seq_v = bseq_v
         report "tb_eth_tcp: FAIL, not the same SYN-ACK again"
         severity failure;
      assert conn = '0'
         report "tb_eth_tcp: FAIL, on_o is 1 before the connection is open"
         severity failure;
      -- The host's sequence numbers wrap around 0 below.
      hseq_v := X"FFFFF001";
      bseq_v := bseq_v + 1;
      send_seg(C_ACK, 0);
      expect_none;
      assert conn = '1'
         report "tb_eth_tcp: FAIL, on_o is not 1 for an open connection"
         severity failure;
      assert n_renew = 1 and rnw_at = 0
         report "tb_eth_tcp: FAIL, no renewal when the connection opened"
         severity failure;

      -- Data, the same again, data out of order, and a wrong checksum
      send_data(5);
      send_data(C_MSS);
      hseq_v := hseq_v - 5;
      hd_v   := hd_v - 5;
      send_seg(C_ACK, 5);
      hseq_v := hseq_v + 5;
      hd_v   := hd_v + 5;
      expect_ack;
      hseq_v := hseq_v + 100;
      send_seg(C_ACK, 5);
      hseq_v := hseq_v - 100;
      expect_ack;
      send_seg(C_ACK, 5, bad => true);
      expect_none;
      -- A keepalive probe, at the sequence number before the next, gets an
      -- ACK.
      hseq_v := hseq_v - 1;
      send_seg(C_ACK, 0);
      hseq_v := hseq_v + 1;
      expect_ack;
      assert n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, the link got the wrong bytes"
         severity failure;
      -- The SYN again gets an ACK.
      send(seg(C_HIP, C_PORT, 40000, X"FFFFF000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect_ack;
      -- Many segments, past 2^32 of the host's sequence numbers, with
      -- options
      for i in 1 to 8 loop
         send_data(C_MSS, i mod 4);
      end loop;
      -- The link side takes a byte every two cycles.
      wait for 100 us;
      assert n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, the link got the wrong bytes"
         severity failure;

      -- The link's output, in segments of at most C_MSS bytes
      link_out(101);
      link_out(1500);
      link_out(3000);
      -- An ACK of data not sent is not taken, and gets an ACK.
      bseq_v := bseq_v + 1000;
      send_seg(C_ACK, 0);
      bseq_v := bseq_v - 1000;
      expect_ack;

      -- At most the host's window, unacknowledged
      send_seg(C_ACK, 0, win => 300);
      ltx_req <= ltx_req + 1000;
      total_v := 0;
      while total_v < 1000 loop
         expect_data;
         total_v := total_v + n_v;
         assert n_v <= 300
            report "tb_eth_tcp: FAIL, the window is not kept"
            severity failure;
         -- Nothing more until the ACK
         if total_v < 1000 then
            expect_none(10 us);
         end if;
         send_seg(C_ACK, 0, win => 300);
      end loop;
      send_seg(C_ACK, 0);

      -- A window of 0: a byte goes beyond it after each timeout, for as
      -- long as the host answers, and the rest when the window opens.
      send_seg(C_ACK, 0, win => 0);
      ltx_req <= ltx_req + 10;
      expect_none(C_RTO / 2);
      for i in 1 to 30 loop
         expect_data(2 * C_RTO);
         assert n_v = 1
            report "tb_eth_tcp: FAIL, not a probe of one byte"
            severity failure;
         bseq_v := bseq_v - 1;
         bd_v   := bd_v - 1;
         send_seg(C_ACK, 0, win => 0);
      end loop;
      -- The window opens, and the host takes the next probe.
      expect_data(2 * C_RTO);
      send_seg(C_ACK, 0);
      expect_data;
      assert n_v = 9
         report "tb_eth_tcp: FAIL, not the data after the window opened"
         severity failure;
      send_seg(C_ACK, 0);

      -- The window of an older segment, which came late, is not taken.
      send_data(5);
      send_data(5);
      hseq_v := hseq_v - 10;
      send_seg(C_ACK, 0, win => 0);
      hseq_v := hseq_v + 10;
      expect_ack;
      ltx_req <= ltx_req + 10;
      expect_data(C_RTO / 2);
      assert n_v = 10
         report "tb_eth_tcp: FAIL, the window of an older segment was taken"
         severity failure;
      send_seg(C_ACK, 0);

      -- Data that is not acknowledged comes again.
      ltx_req <= ltx_req + 50;
      expect_data;
      bseq_v := bseq_v - 50;
      bd_v   := bd_v - 50;
      expect_data(2 * C_RTO);
      assert n_v = 50
         report "tb_eth_tcp: FAIL, not the same data again"
         severity failure;
      send_seg(C_ACK, 0);
      expect_none(2 * C_RTO);

      -- An ACK that comes while data is sent again covers it too.
      ltx_req <= ltx_req + 1000;
      expect_data;
      expect_data;
      tx_stop <= '1';
      wait for 2 * C_RTO;
      send_seg(C_ACK, 0);
      tx_stop <= '0';
      expect(1 ms, sport_v);
      assert n_v = C_MSS and seq_v = bseq_v - 1000
         report "tb_eth_tcp: FAIL, not the data again"
         severity failure;
      expect_none(2 * C_RTO);

      -- Data that does not fit is dropped, and the window grows again.
      hold <= '1';
      for i in 1 to 3 loop
         send_data(C_MSS);
         -- The link side holds one byte that it has not taken.
         assert win_v - (2048 - i * C_MSS) <= 1
            report "tb_eth_tcp: FAIL, a wrong window"
            severity failure;
      end loop;
      send_seg(C_ACK, C_MSS);
      expect_ack;
      assert win_v - (2048 - 3 * C_MSS) <= 1
         report "tb_eth_tcp: FAIL, a wrong window"
         severity failure;
      hold <= '0';
      expect_ack;
      assert win_v >= 1024 + 2048 - 3 * C_MSS
         report "tb_eth_tcp: FAIL, the window was not told"
         severity failure;
      send_data(C_MSS);
      wait for 40 us;
      assert n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, the link got the wrong bytes"
         severity failure;

      -- A frame longer than the 2047 bytes that are read, with data up to
      -- past that, writes no more than its data, and so overwrites no
      -- input that the link side has not taken.
      hold <= '1';
      send_data(10);
      send_long(seg(C_HIP, C_PORT, sport_v, hseq_v, bseq_v, C_ACK, 8192, 0, 0, false), 2200,
                2040);
      expect_none(10 us);
      hold <= '0';
      wait for 1 us;
      assert n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, a long frame overwrote the input"
         severity failure;

      -- The host's FIN: a break after the data, and output still goes to
      -- the host.
      -- A FIN out of order is not taken.
      hseq_v := hseq_v + 50;
      send_seg(C_FIN or C_ACK, 0);
      hseq_v := hseq_v - 50;
      expect_ack;
      -- A FIN with data, while the link side does not take it
      hold   <= '1';
      send_seg(C_FIN or C_ACK, 7);
      hseq_v := hseq_v + 8;
      hd_v   := hd_v + 7;
      expect_ack;
      wait for 1 us;
      assert n_break = 0
         report "tb_eth_tcp: FAIL, a break too soon"
         severity failure;
      hold   <= '0';
      wait for 1 us;
      assert n_break = 1 and brk_at = hd_v and n_log = hd_v
         report "tb_eth_tcp: FAIL, no break after the data"
         severity failure;
      link_out(10);
      -- The first SYN again is not a new connection, and gets an ACK.
      send(seg(C_HIP, C_PORT, 40000, X"FFFFF000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect_ack;
      expect_none(10 us);

      -- A new connection from another port: the old one gets the output
      -- that came before, then its FIN, and the new one opens when the host
      -- has acknowledged that.
      ltx_req <= ltx_req + 20;
      wait for 100 ns;
      send(seg(C_HIP, C_PORT, 40001, X"00005000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect_data;
      expect(1 ms, 40000);
      assert flags_v = X"11" and seq_v = bseq_v
         report "tb_eth_tcp: FAIL, no FIN"
         severity failure;
      expect_none(10 us);
      -- The FIN comes again when the host acknowledges only the data.
      send_seg(C_ACK, 0);
      expect(2 * C_RTO, 40000);
      assert flags_v = X"11" and seq_v = bseq_v
         report "tb_eth_tcp: FAIL, the FIN did not come again"
         severity failure;
      -- The host's FIN again: its ACK is after this side's FIN.
      hseq_v := hseq_v - 1;
      send_seg(C_FIN or C_ACK, 0);
      hseq_v := hseq_v + 1;
      bseq_v := bseq_v + 1;
      expect_ack;
      send_seg(C_ACK, 0);
      sport_v := 40001;
      expect(1 ms, 40001);
      assert flags_v = X"12" and ack_v = X"00005001"
         report "tb_eth_tcp: FAIL, not a SYN-ACK for the new connection"
         severity failure;
      assert conn = '1'
         report "tb_eth_tcp: FAIL, the link left the new connection"
         severity failure;
      hseq_v := X"00005001";
      bseq_v := seq_v + 1;
      send_seg(C_ACK, 0);
      -- The new connection renews the line's input, after the break.
      wait for 1 us;
      assert n_renew = 2 and rnw_at = hd_v and n_log = hd_v
         report "tb_eth_tcp: FAIL, no renewal for the new connection after the break"
         severity failure;
      -- The output after the SYN goes to the new connection.
      ltx_req <= ltx_req + 20;
      total_v := 0;
      while total_v < 20 loop
         expect_data;
         total_v := total_v + n_v;
      end loop;
      send_seg(C_ACK, 0);
      wait for 1 us;
      hold <= '1';
      send_data(3);

      -- A SYN from another IP address does not replace the connection, and
      -- gets a RST with an ACK past it; so does an ACK from another port of
      -- the host, at its acknowledgment number, and a RST gets nothing.
      -- An RST ends the connection, once the link side has taken the input.
      send(seg(C_HIP2, C_PORT, 40002, X"00007000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect(1 ms, 40002, C_HIP2);
      assert flags_v = (C_RST or C_ACK) and seq_v = 0 and ack_v = X"00007001" and n_v = 0
         report "tb_eth_tcp: FAIL, no RST for a SYN from another IP address"
         severity failure;
      send(seg(C_HIP, C_PORT, 40100, X"00008000", X"12345678", C_ACK, 8192, 0, 0, false));
      expect(1 ms, 40100);
      assert flags_v = C_RST and seq_v = X"12345678" and n_v = 0
         report "tb_eth_tcp: FAIL, no RST for an ACK from another port"
         severity failure;
      send(seg(C_HIP, C_PORT, 40100, X"00008000", X"12345678", C_RST, 8192, 0, 0, false));
      expect_none;
      hseq_v := hseq_v + 100000;
      send_seg(C_RST, 0);
      hseq_v := hseq_v - 100000;
      wait for 1 us;
      assert conn = '1'
         report "tb_eth_tcp: FAIL, an RST out of the window ended the connection"
         severity failure;
      send_seg(C_RST, 0);
      -- Output while the input drains is dropped.
      ltx_req <= ltx_req + 5;
      bd_v    := bd_v + 5;
      wait for 1 us;
      assert conn = '1' and n_log < hd_v
         report "tb_eth_tcp: FAIL, the link left before it took the input"
         severity failure;
      hold <= '0';
      wait for 1 us;
      assert conn = '0' and n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, the RST did not end the connection after the input"
         severity failure;
      expect_none(10 us);
      assert n_ltx = ltx_req
         report "tb_eth_tcp: FAIL, the output was not dropped"
         severity failure;
      -- With no connection, an ACK gets a RST at its acknowledgment number,
      -- a segment without ACK a RST with an ACK past its data and FIN, and
      -- a RST nothing.
      send(seg(C_HIP, C_PORT, 40101, X"00009000", X"ABCD0000", C_ACK, 8192, 0, 0, false));
      expect(1 ms, 40101);
      assert flags_v = C_RST and seq_v = X"ABCD0000" and n_v = 0
         report "tb_eth_tcp: FAIL, no RST for an ACK without a connection"
         severity failure;
      send(seg(C_HIP, C_PORT, 40101, X"00009000", X"00000000", C_FIN, 8192, 2, 0, false));
      expect(1 ms, 40101);
      assert flags_v = (C_RST or C_ACK) and seq_v = 0 and ack_v = X"00009003" and n_v = 0
         report "tb_eth_tcp: FAIL, no RST with ACK for a segment without ACK"
         severity failure;
      send(seg(C_HIP, C_PORT, 40101, X"00009000", X"ABCD0000", C_RST or C_ACK, 8192, 0, 0, false));
      expect_none;
      assert conn = '0' and n_log = hd_v
         report "tb_eth_tcp: FAIL, a segment without a connection changed something"
         severity failure;

      -- A break waits for the input before it, also when a new connection's
      -- input comes after it, and the new connection's renewal waits
      -- behind the break, at the same place.
      nr_v := n_renew;
      hold <= '1';
      open_conn(40003, X"00009000");
      send_data(4);
      send_seg(C_FIN or C_ACK, 0);
      hseq_v := hseq_v + 1;
      expect_ack;
      send_seg(C_RST, 0);
      open_conn(40004, X"0000A000");
      send_data(6);
      send_seg(C_RST, 0);
      wait for 1 us;
      assert n_break = 1 and conn = '1'
         report "tb_eth_tcp: FAIL, a break before the input"
         severity failure;
      hold <= '0';
      wait for 1 us;
      assert n_break = 2 and brk_at = hd_v - 6 and n_renew = nr_v + 2 and rnw_at = hd_v - 6 and
             n_log = hd_v and not lrx_bad and conn = '0'
         report "tb_eth_tcp: FAIL, the break and the renewal are not after the input before them"
         severity failure;

      -- A new connection before the host's FIN, as when the FIN was lost:
      -- the old one gets the output and a FIN, and still takes data and the
      -- host's FIN.
      open_conn(40005, X"0000B000");
      send_data(5);
      ltx_req <= ltx_req + 20;
      wait for 1 us;
      send(seg(C_HIP, C_PORT, 40006, X"0000C000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect_data;
      expect(1 ms, 40005);
      assert flags_v = X"11" and seq_v = bseq_v and conn = '1'
         report "tb_eth_tcp: FAIL, no FIN before the host's"
         severity failure;
      bseq_v := bseq_v + 1;
      send_seg(C_FIN or C_ACK, 3);
      hseq_v := hseq_v + 4;
      hd_v   := hd_v + 3;
      expect_ack;
      wait for 1 us;
      assert n_break = 3 and brk_at = hd_v and n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, no break after the old connection's data"
         severity failure;
      -- The old connection has ended, so an ACK of it gets a RST, after the
      -- new connection's SYN-ACK.
      send_seg(C_ACK, 0);
      old_v   := bseq_v;
      sport_v := 40006;
      expect(1 ms, 40006);
      assert flags_v = X"12" and ack_v = X"0000C001" and conn = '1'
         report "tb_eth_tcp: FAIL, not a SYN-ACK for the new connection"
         severity failure;
      hseq_v := X"0000C001";
      bseq_v := seq_v + 1;
      expect(1 ms, 40005);
      assert flags_v = C_RST and seq_v = old_v
         report "tb_eth_tcp: FAIL, no RST for the ended connection"
         severity failure;
      -- Data in the ACK of the SYN-ACK
      send_data(2);
      -- A new connection without a FIN at all, as after a crash: the RST
      -- of the old one opens the new one, and is a break.
      send(seg(C_HIP, C_PORT, 40007, X"0000D000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect(1 ms, 40006);
      assert flags_v = X"11" and seq_v = bseq_v
         report "tb_eth_tcp: FAIL, no FIN for the old connection"
         severity failure;
      send_seg(C_RST, 0);
      expect(1 ms, 40007);
      assert flags_v = X"12" and ack_v = X"0000D001"
         report "tb_eth_tcp: FAIL, not a SYN-ACK after the RST"
         severity failure;
      wait for 1 us;
      assert n_break = 4 and brk_at = hd_v and n_log = hd_v
         report "tb_eth_tcp: FAIL, no break at the end of the old connection"
         severity failure;
      sport_v := 40007;
      hseq_v  := X"0000D001";
      bseq_v  := seq_v + 1;
      send_seg(C_ACK, 0);
      -- An RST while data is out ends the connection, and the timer with it.
      ltx_req <= ltx_req + 10;
      expect_data;
      send_seg(C_RST, 0);
      expect_none(2 * C_RTO);
      assert conn = '0'
         report "tb_eth_tcp: FAIL, the RST did not end the connection with data out"
         severity failure;

      -- The parser's edges: a data offset below 5, and an IP total length
      -- shorter than the headers, are not good, with right checksums.
      f_v       := seg(C_HIP, C_PORT, 40200, X"00010000", X"00000000", C_SYN, 8192, 0, 0, false);
      f_v.b(46) := X"40";
      send(resum(f_v));
      expect_none(10 us);
      f_v           := seg(C_HIP, C_PORT, 40200, X"00010000", X"00000000", C_SYN, 8192, 0, 0, false);
      f_v.b(16 to 17) := X"00" & X"1E";
      send(resum(f_v));
      expect_none(10 us);
      assert conn = '0'
         report "tb_eth_tcp: FAIL, a bad header opened a connection"
         severity failure;

      -- A SYN with ACK and no connection gets a RST at its acknowledgment
      -- number.
      send(seg(C_HIP, C_PORT, 40201, X"00011000", X"55AA0000", C_SYN or C_ACK, 8192, 0, 0, false));
      expect(1 ms, 40201);
      assert flags_v = C_RST and seq_v = X"55AA0000" and n_v = 0
         report "tb_eth_tcp: FAIL, no RST for a SYN with ACK"
         severity failure;

      -- A SYN with a FIN opens a connection for the SYN alone, and the FIN
      -- after the handshake is taken.
      sport_v := 40202;
      hseq_v  := X"00012000";
      send(seg(C_HIP, C_PORT, 40202, hseq_v, X"00000000", C_SYN or C_FIN, 8192, 0, 0, false, C_IP, 5));
      expect(1 ms, 40202);
      assert flags_v = X"12" and ack_v = hseq_v + 1
         report "tb_eth_tcp: FAIL, the SYN-ACK of a SYN with a FIN"
         severity failure;
      hseq_v := hseq_v + 1;
      bseq_v := seq_v + 1;
      send_seg(C_ACK, 0);
      nb_v   := n_break;
      send_seg(C_FIN or C_ACK, 0);
      hseq_v := hseq_v + 1;
      expect_ack;
      wait for 1 us;
      assert n_break = nb_v + 1 and brk_at = hd_v
         report "tb_eth_tcp: FAIL, no break for the FIN after a SYN with a FIN"
         severity failure;
      send_seg(C_RST, 0);
      wait for 1 us;

      -- A SYN with data opens a connection for the SYN alone, and the data
      -- after the handshake is taken, once.
      sport_v := 40203;
      hseq_v  := X"00013000";
      send(seg(C_HIP, C_PORT, 40203, hseq_v, X"00000000", C_SYN, 8192, 5, hd_v, false, C_IP, 5));
      expect(1 ms, 40203);
      assert flags_v = X"12" and ack_v = hseq_v + 1
         report "tb_eth_tcp: FAIL, the SYN-ACK of a SYN with data"
         severity failure;
      hseq_v := hseq_v + 1;
      bseq_v := seq_v + 1;
      send_seg(C_ACK, 0);
      send_data(5);
      wait for 1 us;
      assert n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, the data of a SYN"
         severity failure;

      -- A partial ACK frees what it covers, and after the timeout the rest
      -- comes again from its sequence number.
      ltx_req <= ltx_req + 50;
      expect_data;
      assert n_v = 50
         report "tb_eth_tcp: FAIL, not the data for the partial ACK"
         severity failure;
      bseq_v := bseq_v - 30;
      bd_v   := bd_v - 30;
      send_seg(C_ACK, 0);
      expect_data(2 * C_RTO);
      assert n_v = 30
         report "tb_eth_tcp: FAIL, not the rest after a partial ACK"
         severity failure;
      send_seg(C_ACK, 0);

      -- A segment with old bytes and new ones is dropped whole, and gets an
      -- ACK; the new ones then are taken.
      hseq_v := hseq_v - 3;
      hd_v   := hd_v - 3;
      send_seg(C_ACK, 6);
      hseq_v := hseq_v + 3;
      hd_v   := hd_v + 3;
      expect_ack;
      send_data(3);

      -- An old ACK, before una_seq, is not taken, nor its window, but its
      -- data is.
      bseq_v := bseq_v - 1000;
      send_seg(C_ACK, 2, win => 0);
      bseq_v := bseq_v + 1000;
      hseq_v := hseq_v + 2;
      hd_v   := hd_v + 2;
      expect_ack;
      ltx_req <= ltx_req + 10;
      expect_data(C_RTO / 2);
      assert n_v = 10
         report "tb_eth_tcp: FAIL, the window of an old ACK was taken"
         severity failure;
      send_seg(C_ACK, 0);

      -- Data or a FIN without ACK is dropped, with no answer.
      send_seg(X"00", 3);
      send_seg(C_FIN, 0);
      nb_v := n_break;
      expect_none(10 us);
      assert n_log = hd_v and n_break = nb_v and conn = '1'
         report "tb_eth_tcp: FAIL, a segment without ACK was taken"
         severity failure;

      -- An ACK of what was not sent gets an ACK, and its data is dropped.
      bseq_v := bseq_v + 1000;
      send_seg(C_ACK, 2);
      bseq_v := bseq_v - 1000;
      expect_ack;
      wait for 1 us;
      assert n_log = hd_v
         report "tb_eth_tcp: FAIL, the data of an ACK of what was not sent"
         severity failure;

      -- An RST from another IP address does nothing.
      send(seg(C_HIP2, C_PORT, sport_v, hseq_v, X"00000000", C_RST, 8192, 0, 0, false));
      expect_none(10 us);
      assert conn = '1'
         report "tb_eth_tcp: FAIL, an RST from another IP address ended the connection"
         severity failure;

      -- A FIN ahead of its data gets an ACK, and is not taken; the data and
      -- the FIN in order then are, with one break.
      hseq_v := hseq_v + 4;
      send_seg(C_FIN or C_ACK, 0);
      hseq_v := hseq_v - 4;
      expect_ack;
      wait for 1 us;
      assert n_break = nb_v
         report "tb_eth_tcp: FAIL, a FIN ahead of its data was taken"
         severity failure;
      send_seg(C_FIN or C_ACK, 4);
      hseq_v := hseq_v + 5;
      hd_v   := hd_v + 4;
      expect_ack;
      wait for 1 us;
      assert n_break = nb_v + 1 and brk_at = hd_v and n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, no break after the data before the FIN"
         severity failure;

      -- A SYN from the connection's own port with another sequence number,
      -- as after a reboot of the host, replaces the connection: the old one
      -- gets its FIN, the host's RST ends it, and the new one opens.
      send(seg(C_HIP, C_PORT, sport_v, X"00090000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect(1 ms, sport_v);
      assert flags_v = X"11" and seq_v = bseq_v
         report "tb_eth_tcp: FAIL, no FIN before the SYN from the same port"
         severity failure;
      send_seg(C_RST, 0);
      expect(1 ms, sport_v);
      assert flags_v = X"12" and ack_v = X"00090001"
         report "tb_eth_tcp: FAIL, no SYN-ACK after the SYN from the same port"
         severity failure;
      hseq_v := X"00090001";
      bseq_v := seq_v + 1;
      send_seg(C_ACK, 0);
      send_data(2);
      send_seg(C_RST, 0);
      wait for 1 us;

      -- Both sides' sequence numbers wrap around 2^32 in one connection:
      -- the host's start at X"FFFFFF00", and the server's just before it.
      wait until rising_edge(clk);
      isn <= force X"FFFFFF00";
      wait until rising_edge(clk);
      isn <= release;
      open_conn(40204, X"FFFFFF00");
      assert seq_v(31 downto 12) = X"FFFFF"
         report "tb_eth_tcp: FAIL, the server's sequence number is not near 2^32"
         severity failure;
      for i in 1 to 3 loop
         send_data(200);
      end loop;
      link_out(1200);
      assert hseq_v(31 downto 12) = X"00000" and bseq_v(31 downto 12) = X"00000"
         report "tb_eth_tcp: FAIL, the sequence numbers did not wrap"
         severity failure;
      wait for 1 us;
      assert n_log = hd_v and not lrx_bad
         report "tb_eth_tcp: FAIL, the link got the wrong bytes across 2^32"
         severity failure;
      send_seg(C_RST, 0);
      wait for 1 us;

      -- An RST ends a connection that waits for the ACK of its SYN-ACK.
      send(seg(C_HIP2, C_PORT, 40008, X"0000E000", X"00000000", C_SYN, 8192, 0, 0, false));
      expect(1 ms, 40008, C_HIP2);
      assert flags_v = X"12"
         report "tb_eth_tcp: FAIL, not a SYN-ACK"
         severity failure;
      send(seg(C_HIP2, C_PORT, 40008, X"0000E001", X"00000000", C_RST, 8192, 0, 0, false));
      expect_none(2 * C_RTO);
      assert conn = '0'
         report "tb_eth_tcp: FAIL, the RST did not end the SYN_RCVD connection"
         severity failure;

      -- A SYN-ACK that is never acknowledged ends the connection.
      send(seg(C_HIP2, C_PORT, 40002, X"00007000", X"00000000", C_SYN, 8192, 0, 0, false));
      for i in 1 to C_TRIES loop
         expect(2 * C_RTO, 40002, C_HIP2);
         assert flags_v = X"12"
            report "tb_eth_tcp: FAIL, not a SYN-ACK"
            severity failure;
      end loop;
      expect_none(2 * C_RTO);
      assert conn = '0'
         report "tb_eth_tcp: FAIL, the connection did not end"
         severity failure;

      assert n_fin > 0
         report "tb_eth_tcp: FAIL, no ACK of a FIN"
         severity failure;
      report "tb_eth_tcp: PASS, " & integer'image(n_got) & " segments";
      finish;
   end process p_host;

   -- vsg_on length_003

end architecture simulation;
