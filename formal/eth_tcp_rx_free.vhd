-- A free parser of the TCP server's received frames, for formal/eth_tcp.sby:
-- an architecture of src/eth/eth_tcp_rx.vhd's entity that does, on its
-- ports to the connection, anything that the real parser may do, as
-- formal/eth_tcp_rx.sby proves it, so that the connection's job spends no
-- time on frames, a byte at a time, and their checksums. GHDL binds the
-- architecture analyzed last, so eth_tcp.sby analyzes this file after
-- eth_tcp_rx.vhd.
--
-- THEORY OF OPERATION
-- A segment's fields, its length, and its verdict are free, and are
-- taken, at any time from the second cycle after the last segment was
-- taken, as the real parser takes them by byte 47: whether its data is
-- the next of the connection is decided then, from take_i, exp_*_i, and
-- free_i (wr_ok). Its data, while wr_ok is '1', goes to we_o a byte at a
-- time, in any cycles, up to its length, and the segment ends at any time
-- after that; a segment that is good has had all of its data written.
-- From the second cycle after its last byte it is offered, with its
-- fields standing, until seg_ready_i takes it. rx_ready_o is '1'; the
-- frame's bytes are not read. It asserts, as a help for the induction,
-- that the room for the rest of the data stays, which only the writes
-- take.
--
-- RESET
-- Synchronous, to clk_i. Reset drops the segment.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

architecture formal of eth_tcp_rx is

   type   t_phase is (IDLE_PH, DATA_PH, LAST_PH, OFFER_PH);
   signal phase : t_phase := IDLE_PH;

   -- Cycles since the last segment was taken, as far as 2
   signal gap : natural range 0 to 2 := 2;

   -- The segment, and how much of its data has been written
   signal seg   : t_seg                      := (host => C_HOST_NONE, seq => (others => '0'),
                                                 ack => (others => '0'), flags => (others => '0'),
                                                 win => (others => '0'));
   signal len   : natural range 0 to 2 ** 16 := 0;
   signal good  : std_logic                  := '0';
   signal wr_ok : std_logic                  := '0';
   signal n_wr  : natural range 0 to 2 ** 16 := 0;
   signal we    : std_logic;

   -- What the solver picks: a segment starts, a byte is written, the
   -- segment ends, and its fields and verdict
   signal any_start : std_logic;
   signal any_we    : std_logic;
   signal any_end   : std_logic;
   signal any_seg   : t_seg;
   signal any_len   : std_logic_vector(15 downto 0);
   signal any_good  : std_logic;

   attribute anyseq : boolean;
   attribute anyseq of any_start : signal is true;
   attribute anyseq of any_we    : signal is true;
   attribute anyseq of any_end   : signal is true;
   attribute anyseq of any_seg   : signal is true;
   attribute anyseq of any_len   : signal is true;
   attribute anyseq of any_good  : signal is true;

begin

   we <= '1' when phase = DATA_PH and wr_ok = '1' and any_we = '1' and n_wr < len else
         '0';

   rx_ready_o  <= '1';
   we_o        <= we;
   seg_valid_o <= '1' when phase = OFFER_PH else
                  '0';
   good_o      <= good;
   seg_o       <= seg;
   wr_ok_o     <= wr_ok;
   len_o       <= len;

   p_free : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if gap < 2 then
            gap <= gap + 1;
         end if;

         case phase is

            when IDLE_PH =>
               if any_start = '1' and gap = 2 then
                  seg   <= any_seg;
                  len   <= to_integer(any_len);
                  n_wr  <= 0;
                  wr_ok <= '0';
                  if take_i = '1' and any_seg.host.ip = exp_ip_i and
                     any_seg.host.tcp_port = exp_port_i and any_seg.seq = exp_seq_i and
                     any_len /= 0 and to_integer(any_len) <= free_i then
                     wr_ok <= '1';
                  end if;
                  phase <= DATA_PH;
               end if;

            when DATA_PH =>
               if we = '1' then
                  n_wr <= n_wr + 1;
               end if;
               if any_end = '1' then
                  -- A good segment has had all of its data written.
                  good <= '0';
                  if any_good = '1' and (wr_ok = '0' or (we = '0' and n_wr = len) or
                                         (we = '1' and n_wr + 1 = len)) then
                     good <= '1';
                  end if;
                  phase <= LAST_PH;
               end if;

            when LAST_PH =>
               phase <= OFFER_PH;

            when OFFER_PH =>
               if seg_ready_i = '1' then
                  phase <= IDLE_PH;
                  gap   <= 0;
               end if;

         end case;

         if rst_i = '1' then
            phase <= IDLE_PH;
            gap   <= 2;
         end if;
      end if;
   end process p_free;

   -- psl default clock is rising_edge(clk_i);

   -- The room for the rest of the data, which only the writes take
   -- psl f_room_left : assert always phase = DATA_PH and wr_ok = '1' ->
   --    n_wr <= len and len - n_wr <= free_i;

end architecture formal;
