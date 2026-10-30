-- The sender of the TCP server's segments (eth_tcp.vhd): given the header
-- fields of a segment and where its data is in the send buffer, it builds
-- the frame, with its IP and TCP checksums, and writes it to
-- eth_tx_fifo.vhd.
--
-- THEORY OF OPERATION
-- A segment is offered with seg_valid_i, and taken (seg_ready_o) while
-- nothing is sent: its fields, seg_*_i, are kept in seg_* from then, and
-- busy_o is '1' from that cycle until its last byte has gone. Its header
-- is hdr, 54 bytes, without options: the Ethernet header to seg_host.mac
-- from mac_i, the IPv4 header to seg_host.ip from ip_i, with ip_id, which
-- counts the segments sent, and the TCP header to seg_host.tcp_port from
-- G_PORT, with seg_seq, seg_ack, seg_flags, and seg_wnd. The data, seg_n
-- bytes, is read from the send buffer at seg_addr on: rd_addr_o is the
-- address, a register that starts at seg_addr and moves on with each
-- byte read after the header, and the byte comes on rd_data_i in the
-- cycle after, as eth_icmp.vhd reads its memory. The frame is built in two passes over
-- its bytes, from the IP header on. The first (SUM_ST) adds them up for
-- the checksums, in ones' complement: the IP header's words in ip_sum,
-- and the TCP segment's in tcp_sum, after the pseudo header, whose words
-- INIT_ST adds first. The second (SEND_ST) sends them, with the checksums
-- in place of the zeros of the first. In both, tx_idx is the next byte to
-- read, and fetch says that a byte was read in the cycle before, byte
-- fetch_idx; it is kept in byte, with have and byte_idx, for a cycle, for
-- the timing, and added or sent from there. The second pass reads a byte
-- only when tx_ready_i has taken the last one, so a byte takes at least
-- three cycles there.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) seg_valid_i, once '1', stays '1' with the same fields until
--    seg_ready_o is '1', the cycle the segment is taken.
-- b) The segment's data in the send buffer, seg_n_i bytes from seg_addr_i
--    on, stays as it is while busy_o is '1'.
-- c) mac_i and ip_i stay stable while busy_o is '1'.
--
-- With G_FORMAL, it states the properties that formal/eth_tcp_tx.sby
-- proves, under the contracts: a segment is taken only while nothing is
-- sent, and its fields are kept until its last byte has gone; busy_o is
-- '1' exactly from the take until then; a byte offered stays until it is
-- taken; the frame's bytes come in order, 54 + seg_n of them, with
-- tx_last_o on the last; each byte of the header is that of hdr, with the
-- checksums; and each byte of the data is the one read from the send
-- buffer at seg_addr on, in order. The checksums' sums are not proved there, as the solver does
-- not get through ones' complement sums of free words; tb_eth_tcp checks
-- both of every segment.
--
-- RESET
-- Synchronous, to clk_i. Reset drops the segment being sent.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

entity eth_tcp_tx is
   generic (
      G_PORT      : natural := 4510;
      G_ADDR_BITS : natural := 11;
      G_MSS       : natural := 536;
      G_FORMAL    : boolean := false
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- This station's addresses
      mac_i       : in  std_logic_vector(47 downto 0);
      ip_i        : in  std_logic_vector(31 downto 0);
      -- The segment: offered until it is taken, while nothing is sent;
      -- that one is being sent, from the take until its last byte has
      -- gone; the host's addresses, its TCP header, and its data in the
      -- send buffer, kept at the take
      seg_valid_i : in  std_logic;
      seg_ready_o : out std_logic;
      busy_o      : out std_logic;
      seg_host_i  : in  t_host;
      seg_seq_i   : in  std_logic_vector(31 downto 0);
      seg_ack_i   : in  std_logic_vector(31 downto 0);
      seg_flags_i : in  std_logic_vector(7 downto 0);
      seg_wnd_i   : in  std_logic_vector(15 downto 0);
      seg_addr_i  : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      seg_n_i     : in  natural range 0 to G_MSS;
      -- The send buffer: the byte at rd_addr_o, a cycle later
      rd_addr_o   : out std_logic_vector(G_ADDR_BITS - 1 downto 0) := (others => '0');
      rd_data_i   : in  std_logic_vector(7 downto 0);
      -- The frames to send, to eth_tx_fifo.vhd
      tx_data_o   : out std_logic_vector(7 downto 0) := (others => '0');
      tx_last_o   : out std_logic                    := '0';
      tx_valid_o  : out std_logic;
      tx_ready_i  : in  std_logic
   );
end entity eth_tcp_tx;

architecture synthesis of eth_tcp_tx is

   constant C_PORT : std_logic_vector(15 downto 0) := to_stdlogicvector(G_PORT, 16);

   type   t_state is (IDLE_ST, INIT_ST, SUM_ST, SEND_ST);
   signal state : t_state := IDLE_ST;

   -- The segment being sent, as taken
   signal seg_host  : t_host                                    := C_HOST_NONE;
   signal seg_seq   : std_logic_vector(31 downto 0)             := (others => '0');
   signal seg_ack   : std_logic_vector(31 downto 0)             := (others => '0');
   signal seg_flags : std_logic_vector(7 downto 0)              := (others => '0');
   signal seg_wnd   : std_logic_vector(15 downto 0)             := (others => '0');
   signal seg_addr  : std_logic_vector(G_ADDR_BITS - 1 downto 0) := (others => '0');
   signal seg_n     : natural range 0 to G_MSS                  := 0;

   -- The IP ID of the next segment
   signal ip_id : std_logic_vector(15 downto 0) := (others => '0');

   -- The frame's length, the word of the pseudo header being added, the
   -- sums, and the high byte of the word being added
   signal len     : natural range 0 to 54 + G_MSS := 0;
   signal init_k  : natural range 0 to 5          := 0;
   signal ip_sum  : std_logic_vector(15 downto 0) := (others => '0');
   signal tcp_sum : std_logic_vector(15 downto 0) := (others => '0');
   signal hi      : std_logic_vector(7 downto 0)  := (others => '0');
   -- The next byte to read, whether a byte was read, and which; and the
   -- byte, a cycle later
   signal tx_idx    : natural range 0 to 54 + G_MSS := 0;
   signal fetch     : std_logic                     := '0';
   signal fetch_idx : natural range 0 to 54 + G_MSS := 0;
   signal have      : std_logic                     := '0';
   signal byte_idx  : natural range 0 to 54 + G_MSS := 0;
   signal byte      : std_logic_vector(7 downto 0)  := (others => '0');
   signal tx_valid  : std_logic                     := '0';
   signal ip_ck     : std_logic_vector(15 downto 0);
   signal tcp_ck    : std_logic_vector(15 downto 0);
   signal hdr       : t_bytes(0 to 53);
   signal seg_byte  : std_logic_vector(7 downto 0);
   signal init_word : std_logic_vector(15 downto 0);

begin

   seg_ready_o <= '1' when state = IDLE_ST else
                  '0';
   busy_o      <= '1' when state /= IDLE_ST or seg_valid_i = '1' else
                  '0';

   -- The checksums are 0 while they are added up.
   ip_ck  <= not ip_sum when state = SEND_ST else
             X"0000";
   tcp_ck <= not tcp_sum when state = SEND_ST else
             X"0000";

   hdr <= b6(seg_host.mac) & b6(mac_i) & t_bytes'(X"08", X"00", X"45", X"00") &
          b2(X"0028" + seg_n) & b2(ip_id) &
          t_bytes'(X"40", X"00", X"40", X"06") & b2(ip_ck) & b4(ip_i) & b4(seg_host.ip) &
          b2(C_PORT) & b2(seg_host.tcp_port) & b4(seg_seq) & b4(seg_ack) &
          t_bytes'(X"50", seg_flags) & b2(seg_wnd) & b2(tcp_ck) & t_bytes'(X"00", X"00");

   seg_byte <= hdr(fetch_idx) when fetch_idx < 54 else
               rd_data_i;

   -- The pseudo header: the addresses, the protocol, and the TCP length
   with init_k select init_word <=
      ip_i(31 downto 16) when 0,
      ip_i(15 downto 0) when 1,
      seg_host.ip(31 downto 16) when 2,
      seg_host.ip(15 downto 0) when 3,
      X"0006" when 4,
      X"0014" + seg_n when others;

   tx_valid_o <= tx_valid;


   p_tx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- The byte read in the cycle before
         have <= fetch;
         if fetch = '1' then
            byte     <= seg_byte;
            byte_idx <= fetch_idx;
         end if;

         case state is

            when IDLE_ST =>
               init_k  <= 0;
               ip_sum  <= (others => '0');
               tcp_sum <= (others => '0');
               if seg_valid_i = '1' then
                  seg_host  <= seg_host_i;
                  seg_seq   <= seg_seq_i;
                  seg_ack   <= seg_ack_i;
                  seg_flags <= seg_flags_i;
                  seg_wnd   <= seg_wnd_i;
                  seg_addr  <= seg_addr_i;
                  seg_n     <= seg_n_i;
                  state     <= INIT_ST;
               end if;

            when INIT_ST =>
               tcp_sum <= ones_add(tcp_sum, init_word);
               if init_k = 5 then
                  len       <= 54 + seg_n;
                  tx_idx    <= 14;
                  rd_addr_o <= seg_addr;
                  fetch     <= '0';
                  state     <= SUM_ST;
               else
                  init_k <= init_k + 1;
               end if;

            when SUM_ST =>
               if have = '1' then
                  if byte_idx mod 2 = 0 then
                     hi <= byte;
                  elsif byte_idx <= 33 then
                     ip_sum <= ones_add(ip_sum, hi & byte);
                  else
                     tcp_sum <= ones_add(tcp_sum, hi & byte);
                  end if;
               end if;
               fetch <= '0';
               if tx_idx < len then
                  fetch     <= '1';
                  fetch_idx <= tx_idx;
                  tx_idx    <= tx_idx + 1;
                  if tx_idx >= 54 then
                     rd_addr_o <= rd_addr_o + 1;
                  end if;
               elsif fetch = '0' and have = '0' then
                  -- An odd byte at the end, with a zero after it
                  if len mod 2 = 1 then
                     tcp_sum <= ones_add(tcp_sum, hi & X"00");
                  end if;
                  tx_idx    <= 0;
                  rd_addr_o <= seg_addr;
                  state     <= SEND_ST;
               end if;

            when SEND_ST =>
               if tx_ready_i = '1' and tx_valid = '1' then
                  tx_valid <= '0';
                  if tx_last_o = '1' then
                     ip_id <= ip_id + 1;
                     state <= IDLE_ST;
                  end if;
               end if;
               if have = '1' then
                  tx_data_o <= byte;
                  tx_last_o <= '1' when byte_idx = len - 1 else '0';
                  tx_valid  <= '1';
               end if;
               fetch <= '0';
               if fetch = '0' and have = '0' and tx_idx < len and
                  (tx_valid = '0' or tx_ready_i = '1') then
                  fetch     <= '1';
                  fetch_idx <= tx_idx;
                  tx_idx    <= tx_idx + 1;
                  if tx_idx >= 54 then
                     rd_addr_o <= rd_addr_o + 1;
                  end if;
               end if;

         end case;

         if rst_i = '1' then
            state    <= IDLE_ST;
            fetch    <= '0';
            have     <= '0';
            tx_valid <= '0';
         end if;
      end if;
   end process p_tx;


   gen_formal : if G_FORMAL generate
      -- The bytes of the frame taken so far, the index of the byte offered,
      -- and the address that the byte was read from, with the one read
      -- for byte
      signal f_cnt     : natural range 0 to 54 + G_MSS := 0;
      signal f_tx_idx  : natural range 0 to 54 + G_MSS := 0;
      signal f_tx_addr : std_logic_vector(G_ADDR_BITS - 1 downto 0);
      signal f_addr    : std_logic_vector(G_ADDR_BITS - 1 downto 0);
      signal f_rd      : std_logic_vector(G_ADDR_BITS - 1 downto 0);
      signal f_data    : std_logic_vector(7 downto 0);
      signal f_byte    : std_logic_vector(G_ADDR_BITS - 1 downto 0);
      signal f_sent    : std_logic;
   begin

      f_sent <= tx_valid and tx_ready_i;
      -- Where rd_addr_o should be: at seg_addr, and on with each byte of
      -- data read
      f_addr <= seg_addr + (tx_idx - 54) when tx_idx >= 54 else
                seg_addr;

      p_cnt : process (clk_i)
      begin
         if rising_edge(clk_i) then
            f_rd <= rd_addr_o;
            if fetch = '1' then
               f_byte <= f_rd;
            end if;
            if state = SEND_ST and have = '1' then
               f_tx_idx  <= byte_idx;
               f_tx_addr <= f_byte;
            end if;
            if f_sent = '1' then
               f_cnt <= f_cnt + 1;
               if tx_last_o = '1' then
                  f_cnt <= 0;
               end if;
            end if;
            if rst_i = '1' then
               f_cnt <= 0;
            end if;
         end if;
      end process p_cnt;

      -- psl default clock is rising_edge(clk_i);

      -- psl f_ready : assert always (seg_ready_o = '1') = (state = IDLE_ST);
      -- psl f_busy : assert always (busy_o = '1') = (state /= IDLE_ST or seg_valid_i = '1');
      -- psl f_take : assert always {seg_valid_i and seg_ready_o and not rst_i} |=>
      --    {state = INIT_ST and seg_host = prev(seg_host_i) and seg_seq = prev(seg_seq_i) and
      --     seg_ack = prev(seg_ack_i) and seg_flags = prev(seg_flags_i) and
      --     seg_wnd = prev(seg_wnd_i) and seg_addr = prev(seg_addr_i) and seg_n = prev(seg_n_i)};
      -- psl f_kept : assert always state /= IDLE_ST and prev(state) /= IDLE_ST ->
      --    seg_host = prev(seg_host) and seg_seq = prev(seg_seq) and seg_ack = prev(seg_ack) and
      --    seg_flags = prev(seg_flags) and seg_wnd = prev(seg_wnd) and
      --    seg_addr = prev(seg_addr) and seg_n = prev(seg_n);
      -- psl f_quiet : assert always state /= SEND_ST -> tx_valid = '0';
      -- psl f_hold : assert always {tx_valid and not tx_ready_i and not rst_i} |=>
      --    {tx_valid = '1' and tx_data_o = prev(tx_data_o) and tx_last_o = prev(tx_last_o)};
      -- psl f_len : assert always state = SUM_ST or state = SEND_ST -> len = 54 + seg_n;
      -- psl f_rd_addr : assert always state = SUM_ST or state = SEND_ST -> rd_addr_o = f_addr;
      -- psl f_tx_idx_len : assert always state = SUM_ST or state = SEND_ST -> tx_idx <= len;
      -- psl f_rest : assert always state = IDLE_ST or state = INIT_ST ->
      --    fetch = '0' and have = '0';
      -- psl f_pipe_sum : assert always state = SUM_ST and fetch = '1' -> fetch_idx = tx_idx - 1;
      -- psl f_pipe : assert always state = SEND_ST ->
      --    (fetch = '1' -> fetch_idx = tx_idx - 1) and
      --    (have = '1' -> byte_idx = tx_idx - 1 and fetch = '0');
      -- psl f_one : assert always state = SEND_ST and (fetch = '1' or have = '1') ->
      --    tx_valid = '0';
      -- psl f_valid_idx : assert always state = SEND_ST and tx_valid = '1' ->
      --    f_tx_idx = tx_idx - 1;
      -- psl f_not_last : assert always state = SEND_ST and tx_valid = '1' and tx_last_o = '0' ->
      --    f_tx_idx < len - 1;
      -- psl f_order : assert always tx_valid = '1' -> f_tx_idx = f_cnt;
      -- psl f_idle_cnt : assert always state /= SEND_ST -> f_cnt = 0;
      -- psl f_cnt_fetch : assert always state = SEND_ST and tx_valid = '0' and fetch = '1' ->
      --    f_cnt = fetch_idx;
      -- psl f_cnt_have : assert always state = SEND_ST and tx_valid = '0' and have = '1' ->
      --    f_cnt = byte_idx;
      -- psl f_cnt_none : assert always state = SEND_ST and tx_valid = '0' and fetch = '0' and
      --    have = '0' -> f_cnt = tx_idx;
      -- psl f_last : assert always tx_valid = '1' -> (tx_last_o = '1') = (f_tx_idx = len - 1);
      -- psl f_hdr : assert always tx_valid = '1' and f_tx_idx < 54 -> tx_data_o = hdr(f_tx_idx);
      -- psl f_fetch : assert always fetch = '1' and fetch_idx >= 54 ->
      --    f_rd = seg_addr + (fetch_idx - 54);
      -- psl f_byte_addr : assert always have = '1' and byte_idx >= 54 ->
      --    f_byte = seg_addr + (byte_idx - 54);
      -- psl f_data_addr : assert always tx_valid = '1' and f_tx_idx >= 54 ->
      --    f_tx_addr = seg_addr + (f_tx_idx - 54);

      -- psl c_send : cover {state = SEND_ST and rst_i = '0'};
      -- psl c_hold : cover {tx_valid and not tx_ready_i and not rst_i};
      -- psl c_wait : cover {seg_valid_i and not seg_ready_o and not rst_i};
   end generate gen_formal;

end architecture synthesis;
