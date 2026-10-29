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
-- buffer as it comes, at wr_addr_i, which the connection moves; the data
-- up to cmt_i is committed, and goes to the link a byte at a time, read at
-- rx_rd (lfetch) and held (lrx_valid_o) until lrx_ready_i takes it. free_o
-- is the room from cmt_i to rx_rd, which the parser lets a segment fill.
-- The host's half-close is a break of the line after the data committed:
-- the connection says so with brk_set_i, in the cycle after it has it,
-- and the break waits (fin_rcvd) at its place (brk_ptr, cmt_i then) until
-- the link has taken the bytes before it; lrx_break_o is '1' for a cycle
-- then. Nothing is read past the break meanwhile, as nothing is read past
-- cmt_i. drain_o says that the link has input or a break still to take, a
-- cycle behind, for the timing; the connection stays the line that long
-- after its end.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) cmt_i runs at most 2 ** G_ADDR_BITS bytes past rx_rd, the data the
--    link has taken, so free_o is never exceeded.
-- b) When brk_set_i is '1', the break is after the data committed, cmt_i.
--
-- RESET
-- Synchronous, to clk_i. Reset empties both buffers, as the connection's
-- pointers go to 0 as well, and drops the link's input and the break.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity eth_tcp_buf is
   generic (
      G_ADDR_BITS : natural := 11;
      G_IDLE      : natural := 64
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
      -- A segment's data into the receive buffer (eth_tcp_rx.vhd), the end
      -- of the data committed, and the room after it
      wr_we_i     : in  std_logic;
      wr_addr_i   : in  std_logic_vector(G_ADDR_BITS downto 0);
      wr_data_i   : in  std_logic_vector(7 downto 0);
      cmt_i       : in  std_logic_vector(G_ADDR_BITS downto 0);
      free_o      : out natural range 0 to 2 ** G_ADDR_BITS;
      -- The host's half-close, after the data committed
      brk_set_i   : in  std_logic;
      -- The link's input, from the receive buffer, and the break
      lrx_data_o  : out std_logic_vector(7 downto 0) := (others => '0');
      lrx_valid_o : out std_logic;
      lrx_ready_i : in  std_logic;
      lrx_break_o : out std_logic                    := '0';
      -- Input or a break that the link has not taken, a cycle behind
      drain_o     : out std_logic                    := '0'
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

   -- The receive buffer: the next byte to the link, the byte read, that it
   -- is being read, and that the link has it; the break that waits, and
   -- its place
   signal rx_rd     : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal rx_rdata  : std_logic_vector(8 downto 0);
   signal lfetch    : std_logic                               := '0';
   signal lrx_valid : std_logic                               := '0';
   signal fin_rcvd  : std_logic                               := '0';
   signal brk_ptr   : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   -- Input or a break that the link has not taken
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

   free_o      <= C_SIZE - to_integer(cmt_i - rx_rd);
   lrx_valid_o <= lrx_valid;
   drain       <= '1' when rx_rd /= cmt_i or lfetch = '1' or lrx_valid = '1' or
                           fin_rcvd = '1' else
                  '0';

   i_rx_ram : entity work.eth_ram
      generic map (
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         wr_clk_i  => clk_i,
         wr_we_i   => wr_we_i,
         wr_addr_i => wr_addr_i(G_ADDR_BITS - 1 downto 0),
         wr_data_i => '0' & wr_data_i,
         rd_clk_i  => clk_i,
         rd_addr_i => rx_rd(G_ADDR_BITS - 1 downto 0),
         rd_data_o => rx_rdata
      ); -- i_rx_ram


   p_buf : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- The link's output
         if tx_we = '1' then
            tail_ptr <= tail_ptr + 1;
            idle     <= 0;
         elsif idle < G_IDLE then
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
         if lfetch = '0' and rx_rd /= cmt_i and not (fin_rcvd = '1' and rx_rd = brk_ptr) and
            (lrx_valid = '0' or lrx_ready_i = '1') then
            lfetch <= '1';
            rx_rd  <= rx_rd + 1;
         end if;
         if fin_rcvd = '1' and rx_rd = brk_ptr and lfetch = '0' and lrx_valid = '0' then
            lrx_break_o <= '1';
            fin_rcvd    <= '0';
         end if;
         -- The half-close, a cycle after the connection has it
         if brk_set_i = '1' then
            fin_rcvd <= '1';
            brk_ptr  <= cmt_i;
         end if;
         drain_o <= drain;

         if rst_i = '1' then
            tail_ptr  <= (others => '0');
            rx_rd     <= (others => '0');
            lfetch    <= '0';
            lrx_valid <= '0';
            fin_rcvd  <= '0';
            drain_o   <= '0';
         end if;
      end if;
   end process p_buf;

end architecture synthesis;
