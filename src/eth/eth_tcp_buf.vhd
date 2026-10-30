-- The two buffers of the TCP server (eth_tcp.vhd), with their link side:
-- the send buffer takes the link's output, and the receive buffer gives
-- the link the data of the segments received, and the host's half-close
-- after it.
--
-- THEORY OF OPERATION
-- Each buffer is 2 ** G_ADDR_BITS bytes of eth_ram.vhd, and a place in it
-- is a pointer a bit wider, so that full and empty differ. The link's
-- output goes into the send buffer at tail_ptr while there is a
-- connection (conn_i) and there is room: the bytes from una_ptr_i, the
-- first that the host has not acknowledged, on are kept. Without a
-- connection, the output is taken and dropped. idle counts the cycles
-- since the last byte, up to G_IDLE, when paused_o says so, and the
-- connection sends what there is. The sender (eth_tcp_tx.vhd) reads the
-- buffer at rd_addr_i, and gets the byte in the cycle after.
-- The parser (eth_tcp_rx.vhd) writes a segment's data into the receive
-- buffer as it comes, at wr_ptr; room_o is the room for it, from wr_ptr
-- to rx_rd. In the cycle after the connection has acted on the segment,
-- it commits the data (cmt_i: cmt_ptr moves to wr_ptr) or discards it
-- (discard_i: wr_ptr goes back to cmt_ptr), so that the next segment's
-- goes where it went; a byte written in the cycle of a commit is after
-- it, and one written in the cycle of a discard goes with the rest. The
-- data up to cmt_ptr goes to the link a byte at a time, read at rx_rd
-- (lfetch) and held (lrx_valid_o) until lrx_ready_i takes it. free_o is
-- the room from cmt_ptr to rx_rd, the receive window, which is room_o
-- while nothing is written and not committed, as when a segment starts.
-- The host's half-close is a break of the line after the data committed:
-- the connection says so with brk_set_i, in the cycle after it has it,
-- with the commit of the data before it or after, and the break waits
-- (fin_rcvd) at its place (brk_ptr, cmt_ptr then, that commit included)
-- until the link has taken the bytes before it; lrx_break_o is '1' for a
-- cycle then. Nothing is read past the break meanwhile, as nothing is
-- read past cmt_ptr. A connection that opens renews the line's input,
-- the link's resume (nicemon.vhd): the connection says so with rnw_set_i,
-- in the cycle after it opens, before the commit of its own first data,
-- and the renewal waits (rnw_rcvd) at its place (rnw_ptr, cmt_ptr then,
-- that commit excluded) until the link has taken the bytes before it, and
-- the break before it; lrx_renew_o is '1' for a cycle then, alone. When
-- a break and a renewal wait at one place, the one set first goes first
-- (brk_first). on_o says that the link is on the connection: there is one
-- (conn_i), or the link has input, a break, or a renewal still to take, a
-- cycle behind, for the timing; so the link becomes the connection's a
-- cycle after it opens, and stays with it that long after its end, and a
-- byte, the break, or the renewal goes to the link only while on_o is '1'.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) wr_we_i comes only while room_o is more than 0: the parser checks a
--    segment's length against it before the data, and the link only
--    frees room.
-- b) brk_set_i comes no earlier than the cmt_i of the data before the
--    break: with it, or after.
-- c) rnw_set_i comes no later than the cmt_i of the data after the
--    renewal: with it, or before, and not in a cycle with brk_set_i.
--
-- With G_FORMAL, it states the properties that formal/eth_tcp_buf.sby
-- proves, under the contracts: the link's output is taken only into room
-- below una_ptr_i, and dropped without a connection; the data written
-- and the data committed stay in order, within a buffer of what the link
-- has taken, and a commit or a discard moves the one to the other; a
-- byte read goes to the link in the cycle after, and stays until it is
-- taken; the break waits from brk_set_i, after the data committed, until
-- the bytes before it are taken, and comes alone; the renewal waits from
-- rnw_set_i, before the data committed with it, until the bytes and the
-- break before it are taken, and comes alone, never with the break, and
-- not while a break set before it waits at its place, nor the break
-- while a renewal set before it does; and the link is on while a byte,
-- the break, or the renewal is offered, and from the cycle after a
-- connection opens.
--
-- RESET
-- Synchronous, to clk_i. Reset empties both buffers, as the connection's
-- una_ptr_i goes to 0 as well, and drops the link's input, the break, and
-- the renewal.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity eth_tcp_buf is
   generic (
      G_ADDR_BITS : natural := 11;
      G_IDLE      : natural := 64;
      -- The properties for formal/eth_tcp_buf.sby
      G_FORMAL    : boolean := false
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- The connection: there is one, and its first byte that the host has
      -- not acknowledged
      conn_i      : in  std_logic;
      una_ptr_i   : in  std_logic_vector(G_ADDR_BITS downto 0);
      -- The link's output, into the send buffer: where its next byte goes,
      -- and that it has paused for G_IDLE cycles
      ltx_data_i  : in  std_logic_vector(7 downto 0);
      ltx_valid_i : in  std_logic;
      ltx_ready_o : out std_logic;
      tail_ptr_o  : out std_logic_vector(G_ADDR_BITS downto 0);
      paused_o    : out std_logic;
      -- The send buffer's reads (eth_tcp_tx.vhd): the byte at rd_addr_i, a
      -- cycle later
      rd_addr_i   : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      rd_data_o   : out std_logic_vector(7 downto 0);
      -- A segment's data into the receive buffer (eth_tcp_rx.vhd), as it
      -- comes, and the room for it after the data written; a cycle after
      -- the connection has acted on the segment, that the data written is
      -- committed, or discarded; and the room after the data committed
      wr_we_i     : in  std_logic;
      wr_data_i   : in  std_logic_vector(7 downto 0);
      room_o      : out natural range 0 to 2 ** G_ADDR_BITS;
      cmt_i       : in  std_logic;
      discard_i   : in  std_logic;
      free_o      : out natural range 0 to 2 ** G_ADDR_BITS;
      -- The host's half-close, after the data committed, and a connection
      -- that opens, before the data committed with it
      brk_set_i   : in  std_logic;
      rnw_set_i   : in  std_logic                    := '0';
      -- The link's input, from the receive buffer, the break, and the
      -- renewal of the line's input
      lrx_data_o  : out std_logic_vector(7 downto 0) := (others => '0');
      lrx_valid_o : out std_logic;
      lrx_ready_i : in  std_logic;
      lrx_break_o : out std_logic                    := '0';
      lrx_renew_o : out std_logic                    := '0';
      -- The link is on the connection: there is one, or input, a break, or
      -- a renewal that the link has not taken, a cycle behind
      on_o        : out std_logic                    := '0'
   );
end entity eth_tcp_buf;

architecture synthesis of eth_tcp_buf is

   constant C_SIZE : natural := 2 ** G_ADDR_BITS;

   -- The send buffer: where the next byte goes, the cycles since the last,
   -- that a byte is taken, and the byte read
   signal tail_ptr : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal idle     : natural range 0 to G_IDLE               := 0;
   signal tx_ready : std_logic;
   signal tx_we    : std_logic;
   signal tx_rdata : std_logic_vector(8 downto 0);

   -- The receive buffer: where the next byte goes, the end of the data
   -- committed, the next byte to the link, the byte read, that it is read
   -- now, and in the cycle before, and that the link has it; the break
   -- that waits, and its place
   signal wr_ptr    : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal cmt_ptr   : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal rx_rd     : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal rx_rdata  : std_logic_vector(8 downto 0);
   signal fetch     : std_logic;
   signal lfetch    : std_logic                               := '0';
   signal lrx_valid : std_logic                               := '0';
   signal fin_rcvd  : std_logic                               := '0';
   signal brk_ptr   : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   -- The renewal that waits, its place, and that the break that waits was
   -- set before it
   signal rnw_rcvd  : std_logic                               := '0';
   signal rnw_ptr   : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal brk_first : std_logic                               := '0';
   -- The break, or the renewal, is at the link's place, with no byte being
   -- read or held
   signal brk_due : std_logic;
   signal rnw_due : std_logic;
   -- Input, a break, or a renewal that the link has not taken
   signal drain : std_logic;

begin

   ---------------------------------------------------------------------------
   -- The send buffer
   ---------------------------------------------------------------------------

   tx_ready    <= '1' when conn_i = '1' and to_integer(tail_ptr - una_ptr_i) < C_SIZE else
                  '0';
   ltx_ready_o <= tx_ready or not conn_i;
   tx_we       <= ltx_valid_i and tx_ready;
   tail_ptr_o  <= tail_ptr;
   paused_o    <= '1' when idle = G_IDLE else
                  '0';
   rd_data_o   <= tx_rdata(7 downto 0);

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
         rd_addr_i => rd_addr_i,
         rd_data_o => tx_rdata
      ); -- i_tx_ram

   ---------------------------------------------------------------------------
   -- The receive buffer
   ---------------------------------------------------------------------------

   room_o      <= C_SIZE - to_integer(wr_ptr - rx_rd);
   free_o      <= C_SIZE - to_integer(cmt_ptr - rx_rd);
   lrx_valid_o <= lrx_valid;
   -- The next byte is read: there is one before the commit, the break, and
   -- the renewal, none is being read, and the link has taken the last; the
   -- link has input, a break, or a renewal still to take; and the break or
   -- the renewal is at the link's place
   fetch   <= '1' when lfetch = '0' and rx_rd /= cmt_ptr and
                     not (fin_rcvd = '1' and rx_rd = brk_ptr) and
                     not (rnw_rcvd = '1' and rx_rd = rnw_ptr) and
                     (lrx_valid = '0' or lrx_ready_i = '1') else
            '0';
   drain   <= '1' when rx_rd /= cmt_ptr or lfetch = '1' or lrx_valid = '1' or
                     fin_rcvd = '1' or rnw_rcvd = '1' else
            '0';
   brk_due <= '1' when fin_rcvd = '1' and rx_rd = brk_ptr and lfetch = '0' and lrx_valid = '0' else
              '0';
   rnw_due <= '1' when rnw_rcvd = '1' and rx_rd = rnw_ptr and lfetch = '0' and lrx_valid = '0' else
              '0';

   i_rx_ram : entity work.eth_ram
      generic map (
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         wr_clk_i  => clk_i,
         wr_we_i   => wr_we_i,
         wr_addr_i => wr_ptr(G_ADDR_BITS - 1 downto 0),
         wr_data_i => '0' & wr_data_i,
         rd_clk_i  => clk_i,
         rd_addr_i => rx_rd(G_ADDR_BITS - 1 downto 0),
         rd_data_o => rx_rdata
      ); -- i_rx_ram


   p_buf : process (clk_i)
      variable cmt_v : std_logic_vector(G_ADDR_BITS downto 0);
   begin
      if rising_edge(clk_i) then
         -- The link's output
         if tx_we = '1' then
            tail_ptr <= tail_ptr + 1;
            idle     <= 0;
         elsif idle < G_IDLE then
            idle <= idle + 1;
         end if;

         -- The segment's data, and the connection's verdict on the last
         -- segment's: committed, or discarded
         if wr_we_i = '1' then
            wr_ptr <= wr_ptr + 1;
         end if;
         cmt_v := cmt_ptr;
         if cmt_i = '1' then
            cmt_v := wr_ptr;
         elsif discard_i = '1' then
            wr_ptr <= cmt_ptr;
         end if;
         cmt_ptr <= cmt_v;

         -- The receive buffer to the link, and the host's half-close and
         -- the renewal after the last byte before them
         lrx_break_o <= '0';
         lrx_renew_o <= '0';
         if lrx_ready_i = '1' then
            lrx_valid <= '0';
         end if;
         if lfetch = '1' then
            lrx_data_o <= rx_rdata(7 downto 0);
            lrx_valid  <= '1';
         end if;
         lfetch <= fetch;
         if fetch = '1' then
            rx_rd <= rx_rd + 1;
         end if;
         -- The one set first, when both wait at the link's place
         if brk_due = '1' and (rnw_due = '0' or brk_first = '1') then
            lrx_break_o <= '1';
            fin_rcvd    <= '0';
         elsif rnw_due = '1' then
            lrx_renew_o <= '1';
            rnw_rcvd    <= '0';
         end if;
         -- The half-close, a cycle after the connection has it, after the
         -- data committed, this cycle's included; and the renewal, before
         -- the data committed this cycle, which is the new connection's
         if brk_set_i = '1' then
            fin_rcvd  <= '1';
            brk_ptr   <= cmt_v;
            brk_first <= '0';
         end if;
         if rnw_set_i = '1' then
            rnw_rcvd  <= '1';
            rnw_ptr   <= cmt_ptr;
            brk_first <= fin_rcvd;
         end if;
         on_o <= conn_i or drain;

         if rst_i = '1' then
            tail_ptr    <= (others => '0');
            wr_ptr      <= (others => '0');
            cmt_ptr     <= (others => '0');
            rx_rd       <= (others => '0');
            lfetch      <= '0';
            lrx_valid   <= '0';
            lrx_break_o <= '0';
            lrx_renew_o <= '0';
            fin_rcvd    <= '0';
            rnw_rcvd    <= '0';
            brk_first   <= '0';
            on_o        <= '0';
         end if;
      end if;
   end process p_buf;


   gen_formal : if G_FORMAL generate
      -- Cycles since the link's last output byte, up to G_IDLE
      signal f_quiet : natural range 0 to G_IDLE := 0;
   begin

      p_quiet : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if tx_we = '1' then
               f_quiet <= 0;
            elsif f_quiet < G_IDLE then
               f_quiet <= f_quiet + 1;
            end if;
         end if;
      end process p_quiet;

      -- psl default clock is rising_edge(clk_i);

      -- The send buffer
      -- psl f_we : assert always tx_we = '1' -> tail_ptr - una_ptr_i < C_SIZE;
      -- psl f_off : assert always conn_i = '0' -> ltx_ready_o = '1' and tx_we = '0';
      -- psl f_paused : assert always paused_o = '1' -> f_quiet = G_IDLE;
      -- psl f_not_paused : assert always f_quiet = G_IDLE -> paused_o = '1';

      -- The receive buffer
      -- psl f_bound : assert always
      --    cmt_ptr - rx_rd <= wr_ptr - rx_rd and wr_ptr - rx_rd <= C_SIZE;
      -- psl f_cmt : assert always {cmt_i and not rst_i} |=>
      --    {rst_i = '1' or cmt_ptr = prev(wr_ptr)};
      -- psl f_discard : assert always {discard_i and not cmt_i and not rst_i} |=>
      --    {rst_i = '1' or wr_ptr = prev(cmt_ptr)};
      -- psl f_fetch : assert always fetch = '1' ->
      --    rx_rd /= cmt_ptr and lfetch = '0' and (lrx_valid = '0' or lrx_ready_i = '1');
      -- psl f_read : assert always {fetch and not rst_i} |=> {rst_i = '1' or lfetch = '1'};
      -- psl f_shown : assert always {lfetch and not rst_i} |=> {rst_i = '1' or lrx_valid = '1'};
      -- psl f_hold : assert always {lrx_valid and not lrx_ready_i and not rst_i} |=>
      --    {rst_i = '1' or (lrx_valid = '1' and lrx_data_o = prev(lrx_data_o))};

      -- The break
      -- psl f_break_set : assert always {brk_set_i and not rst_i} |=>
      --    {rst_i = '1' or (fin_rcvd = '1' and brk_ptr = cmt_ptr)};
      -- psl f_break_waits : assert always fin_rcvd = '1' -> brk_ptr - rx_rd <= cmt_ptr - rx_rd;
      -- psl f_break_alone : assert always lrx_break_o = '1' ->
      --    prev(fin_rcvd) = '1' and lrx_valid = '0' and lfetch = '0';
      -- psl f_break_order : assert always lrx_break_o = '1' ->
      --    not (prev(rnw_rcvd) = '1' and prev(rnw_ptr) = prev(brk_ptr) and prev(brk_first) = '0');

      -- The renewal
      -- psl f_renew_set : assert always {rnw_set_i and not rst_i} |=>
      --    {rst_i = '1' or (rnw_rcvd = '1' and rnw_ptr = prev(cmt_ptr))};
      -- psl f_renew_waits : assert always rnw_rcvd = '1' -> rnw_ptr - rx_rd <= cmt_ptr - rx_rd;
      -- psl f_renew_alone : assert always lrx_renew_o = '1' ->
      --    prev(rnw_rcvd) = '1' and lrx_valid = '0' and lfetch = '0' and lrx_break_o = '0';
      -- psl f_renew_order : assert always lrx_renew_o = '1' ->
      --    not (prev(fin_rcvd) = '1' and prev(brk_ptr) = prev(rnw_ptr) and prev(brk_first) = '1');

      -- The link is on
      -- psl f_on_byte : assert always lrx_valid = '1' -> on_o = '1';
      -- psl f_on_break : assert always lrx_break_o = '1' -> on_o = '1';
      -- psl f_on_renew : assert always lrx_renew_o = '1' -> on_o = '1';
      -- psl f_on_conn : assert always {conn_i and not rst_i} |=> {rst_i = '1' or on_o = '1'};

      -- psl c_full : cover {conn_i = '1' and tail_ptr - una_ptr_i = C_SIZE and rst_i = '0'};
      -- psl c_paused : cover {paused_o and not rst_i};
      -- psl c_discard : cover {wr_ptr /= cmt_ptr and discard_i = '1' and rst_i = '0'};
      -- psl c_wrap : cover {rx_rd = C_SIZE + 1 and rst_i = '0'};
      -- psl c_break : cover {lrx_break_o and not rst_i};
      -- psl c_renew : cover {lrx_renew_o and not rst_i};
      -- psl c_break_renew : cover {lrx_break_o = '1' and rst_i = '0'; lrx_renew_o = '1'};
      -- psl c_renew_break : cover {lrx_renew_o = '1' and rst_i = '0'; lrx_break_o = '1'};
      -- psl c_stays : cover {on_o = '1' and conn_i = '0' and rst_i = '0'};
   end generate gen_formal;

end architecture synthesis;
