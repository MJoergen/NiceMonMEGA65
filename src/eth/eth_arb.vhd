-- The arbiter of the Ethernet station's frames to send (eth.vhd): it
-- merges the replies of the ARP and ICMP responders (eth_arp.vhd and
-- eth_icmp.vhd) and the segments of the TCP server (eth_tcp.vhd) into the
-- one stream of the FIFO of frames to send, a whole frame at a time.
--
-- THEORY OF OPERATION
-- The two responders never write at the same time (contract a), so their
-- outputs are simply merged into one, resp, which takes the ARP
-- responder's byte while it is valid, and the ICMP responder's otherwise.
-- The TCP server sends whenever it has a segment, so the output is locked
-- to the responders or to it from the first byte of a frame to its last:
-- the byte taken that is not the last sets the lock to its source, and
-- the last byte frees it. While the lock is free, the responders get the
-- output when one of them is valid, and the TCP server otherwise, so the
-- responders come first when both start in the same cycle. Only the
-- source that has the output sees out_ready_i.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) arp_valid_i and icmp_valid_i are never '1' together, and neither
--    starts a frame while the other is in one: each responder writes a
--    reply only while no frame is read, and a frame gets at most one
--    reply, as one is ARP and the other IPv4.
--
-- With G_FORMAL, it states the properties that formal/eth_arb.sby
-- proves: a source's byte is taken only when the output takes it, and
-- it is that byte that goes out; each byte that goes out is the byte of
-- one source, which is taken; the bytes of a frame, from its first to its
-- last, all come from one source, the responders or the TCP server; and
-- the responders come first when both start in the same cycle.
--
-- RESET
-- Synchronous, to clk_i. Reset frees the lock.

library ieee;
   use ieee.std_logic_1164.all;

entity eth_arb is
   generic (
      -- The properties for formal/eth_arb.sby
      G_FORMAL : boolean := false
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      -- The replies of the two responders, which share arp_ready_o
      arp_data_i   : in  std_logic_vector(7 downto 0);
      arp_last_i   : in  std_logic;
      arp_valid_i  : in  std_logic;
      icmp_data_i  : in  std_logic_vector(7 downto 0);
      icmp_last_i  : in  std_logic;
      icmp_valid_i : in  std_logic;
      resp_ready_o : out std_logic;
      -- The TCP server's segments
      tcp_data_i   : in  std_logic_vector(7 downto 0);
      tcp_last_i   : in  std_logic;
      tcp_valid_i  : in  std_logic;
      tcp_ready_o  : out std_logic;
      -- The frames to send, to eth_tx_fifo.vhd
      out_data_o   : out std_logic_vector(7 downto 0);
      out_last_o   : out std_logic;
      out_valid_o  : out std_logic;
      out_ready_i  : in  std_logic
   );
end entity eth_arb;

architecture synthesis of eth_arb is

   -- The responders' merged output
   signal resp_data  : std_logic_vector(7 downto 0);
   signal resp_last  : std_logic;
   signal resp_valid : std_logic;
   -- Who has the output: the lock, and the grant in this cycle
   type   t_lock is (FREE_LK, RESP_LK, TCP_LK);
   signal lock      : t_lock := FREE_LK;
   signal grant_tcp : std_logic;
   -- The output
   signal out_last  : std_logic;
   signal out_valid : std_logic;

begin

   resp_data  <= arp_data_i when arp_valid_i = '1' else
                 icmp_data_i;
   resp_last  <= arp_last_i when arp_valid_i = '1' else
                 icmp_last_i;
   resp_valid <= arp_valid_i or icmp_valid_i;

   grant_tcp <= '1' when lock = TCP_LK or (lock = FREE_LK and resp_valid = '0') else
                '0';

   out_data_o   <= tcp_data_i when grant_tcp = '1' else
                   resp_data;
   out_last     <= tcp_last_i when grant_tcp = '1' else
                   resp_last;
   out_valid    <= tcp_valid_i when grant_tcp = '1' else
                   resp_valid;
   out_last_o   <= out_last;
   out_valid_o  <= out_valid;
   resp_ready_o <= out_ready_i and not grant_tcp;
   tcp_ready_o  <= out_ready_i and grant_tcp;

   p_lock : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if out_valid = '1' and out_ready_i = '1' then
            if out_last = '1' then
               lock <= FREE_LK;
            elsif grant_tcp = '1' then
               lock <= TCP_LK;
            else
               lock <= RESP_LK;
            end if;
         end if;

         if rst_i = '1' then
            lock <= FREE_LK;
         end if;
      end if;
   end process p_lock;


   gen_formal : if G_FORMAL generate
      -- A byte of each source is taken, and one goes out.
      signal f_resp_take : std_logic;
      signal f_tcp_take  : std_logic;
      signal f_out_take  : std_logic;
      -- The source of the frame that goes out, from its first byte to its
      -- last: none, the responders, or the TCP server
      type   t_src is (NONE_SRC, RESP_SRC, TCP_SRC);
      signal f_src : t_src := NONE_SRC;
   begin

      f_resp_take <= resp_valid and out_ready_i and not grant_tcp;
      f_tcp_take  <= tcp_valid_i and out_ready_i and grant_tcp;
      f_out_take  <= out_valid and out_ready_i;

      p_src : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if f_out_take = '1' then
               if out_last = '1' then
                  f_src <= NONE_SRC;
               elsif f_tcp_take = '1' then
                  f_src <= TCP_SRC;
               else
                  f_src <= RESP_SRC;
               end if;
            end if;

            if rst_i = '1' then
               f_src <= NONE_SRC;
            end if;
         end if;
      end process p_src;

      -- psl default clock is rising_edge(clk_i);

      -- psl f_one_ready : assert always not (resp_ready_o = '1' and tcp_ready_o = '1');
      -- psl f_resp_out : assert always f_resp_take = '1' ->
      --    (f_out_take = '1' and out_data_o = resp_data and out_last = resp_last);
      -- psl f_tcp_out : assert always f_tcp_take = '1' ->
      --    (f_out_take = '1' and out_data_o = tcp_data_i and out_last = tcp_last_i);
      -- psl f_out_src : assert always f_out_take = '1' -> (f_resp_take xor f_tcp_take) = '1';
      -- psl f_arp_byte : assert always (f_resp_take = '1' and arp_valid_i = '1') ->
      --    (out_data_o = arp_data_i and out_last = arp_last_i);
      -- psl f_icmp_byte : assert always (f_resp_take = '1' and icmp_valid_i = '1') ->
      --    (out_data_o = icmp_data_i and out_last = icmp_last_i);
      -- psl f_lock : assert always (f_src = NONE_SRC and lock = FREE_LK) or
      --    (f_src = RESP_SRC and lock = RESP_LK) or (f_src = TCP_SRC and lock = TCP_LK);
      -- psl f_frame_resp : assert always f_src = RESP_SRC -> f_tcp_take = '0';
      -- psl f_frame_tcp : assert always f_src = TCP_SRC -> f_resp_take = '0';
      -- psl f_first : assert always (f_src = NONE_SRC and resp_valid = '1') -> grant_tcp = '0';

      -- psl c_resp_tcp : cover {f_resp_take and out_last and not rst_i; f_tcp_take};
      -- psl c_tcp_resp : cover {f_tcp_take and out_last and not rst_i; f_resp_take};
      -- psl c_tcp_waits : cover {f_src = RESP_SRC and tcp_valid_i = '1' and rst_i = '0'};
      -- psl c_resp_waits : cover {f_src = TCP_SRC and resp_valid = '1' and rst_i = '0'};
      -- psl c_both : cover {f_src = NONE_SRC and resp_valid = '1' and tcp_valid_i = '1' and
      --    out_ready_i = '1' and rst_i = '0'};
   end generate gen_formal;

end architecture synthesis;
