-- The retransmission timer of the TCP server (eth_tcp.vhd): a count of
-- milliseconds that runs while something is out, and runs out after
-- G_RTO_MS of them, up to G_TRIES times.
--
-- THEORY OF OPERATION
-- tick_cnt counts the clock's cycles to a millisecond, G_TICK of them,
-- and a tick is its last cycle, but for the cycles hold_i says to skip:
-- the connection acts on a segment, or ends, in such a cycle, and what
-- it tells the timer lands in the cycle after, so the timer stands still
-- in both (still), as it does in the cycle after it ran out. At a tick,
-- rto_cnt counts the milliseconds while armed_i is '1', and it and tries
-- are 0 otherwise. When it reaches G_RTO_MS - 1 at a tick, timeout_o is
-- '1' for that cycle: the count starts again, and tries goes up, unless
-- it is at G_TRIES - 1 (last_try_o), when the connection ends instead
-- and the tries stay. restart_i clears both counts, and tries_clr_i the
-- tries alone, in the cycle after the connection says so.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) restart_i and tries_clr_i are '1' only in the cycle after hold_i or
--    timeout_o was '1', so that no tick meets them.
--
-- With G_FORMAL, it states the properties that formal/eth_tcp_timer.sby
-- proves: the counts stay in their ranges, the timer runs out only at a
-- tick while it is armed, never in the cycle after it was held or ran
-- out, and not before (G_RTO_MS - 1) * G_TICK - 1 cycles after the
-- count started; each timeout counts a try, but the last; and what the
-- connection tells it lands in the cycle after.
--
-- RESET
-- Synchronous, to clk_i. Reset clears the counts.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity eth_tcp_timer is
   generic (
      G_TICK   : natural;
      G_RTO_MS : natural := 300;
      G_TRIES  : natural := 17;
      -- The properties for formal/eth_tcp_timer.sby
      G_FORMAL : boolean := false
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- The timer runs; the connection acts on a segment or ends, and
      -- what it tells the timer lands in the cycle after: it starts
      -- again, or the tries alone do
      armed_i     : in  std_logic;
      hold_i      : in  std_logic;
      restart_i   : in  std_logic;
      tries_clr_i : in  std_logic;
      -- The timer runs out, and it is on its last try
      timeout_o   : out std_logic;
      last_try_o  : out std_logic
   );
end entity eth_tcp_timer;

architecture synthesis of eth_tcp_timer is

   -- A millisecond, the retransmission timeout, and its count
   signal tick_cnt : natural range 0 to G_TICK   := 0;
   signal rto_cnt  : natural range 0 to G_RTO_MS := 0;
   signal tries    : natural range 0 to G_TRIES  := 0;
   -- The timer ticks, runs out, and stands still
   signal tick    : std_logic;
   signal timeout : std_logic;
   signal still   : std_logic := '0';

begin

   tick       <= '1' when tick_cnt = G_TICK - 1 and hold_i = '0' and still = '0' else
                 '0';
   timeout    <= '1' when tick = '1' and armed_i = '1' and rto_cnt = G_RTO_MS - 1 else
                 '0';
   timeout_o  <= timeout;
   last_try_o <= '1' when tries = G_TRIES - 1 else
                 '0';


   p_timer : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if tick_cnt = G_TICK - 1 then
            tick_cnt <= 0;
         else
            tick_cnt <= tick_cnt + 1;
         end if;
         still <= hold_i or timeout;

         if tick = '1' then
            if armed_i = '0' then
               rto_cnt <= 0;
               tries   <= 0;
            elsif timeout = '1' then
               rto_cnt <= 0;
               if tries < G_TRIES - 1 then
                  tries <= tries + 1;
               end if;
            else
               rto_cnt <= rto_cnt + 1;
            end if;
         end if;

         -- What the connection told the timer in the cycle before
         if restart_i = '1' then
            rto_cnt <= 0;
            tries   <= 0;
         elsif tries_clr_i = '1' then
            tries <= 0;
         end if;

         if rst_i = '1' then
            tick_cnt <= 0;
            rto_cnt  <= 0;
            tries    <= 0;
            still    <= '0';
         end if;
      end if;
   end process p_timer;


   gen_formal : if G_FORMAL generate
      -- Cycles since the count was 0, as far as the properties need
      signal f_since : natural range 0 to G_RTO_MS * G_TICK := 0;
   begin

      p_since : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if rto_cnt = 0 then
               f_since <= 0;
            elsif f_since < G_RTO_MS * G_TICK then
               f_since <= f_since + 1;
            end if;
         end if;
      end process p_since;

      -- psl default clock is rising_edge(clk_i);

      -- psl f_tick_cnt : assert always tick_cnt < G_TICK;
      -- psl f_rto_cnt : assert always rto_cnt < G_RTO_MS;
      -- psl f_tries : assert always tries < G_TRIES;
      -- psl f_last : assert always last_try_o = '1' -> tries = G_TRIES - 1;
      -- psl f_not_last : assert always tries = G_TRIES - 1 -> last_try_o = '1';
      -- psl f_armed : assert always timeout = '1' -> armed_i = '1' and tick_cnt = G_TICK - 1;
      -- psl f_still : assert always {hold_i or timeout} |=> {not timeout};
      -- psl f_apart : assert always not (timeout = '1' and (restart_i = '1' or tries_clr_i = '1'));
      -- psl f_restart : assert always {restart_i} |=> {rto_cnt = 0 and tries = 0};
      -- psl f_tries_clr : assert always {tries_clr_i} |=> {tries = 0};
      -- psl f_unarmed : assert always {tick and not armed_i} |=> {rto_cnt = 0 and tries = 0};
      -- psl f_try : assert always {timeout and not last_try_o and not rst_i} |=>
      --    {rst_i = '1' or (rto_cnt = 0 and tries = prev(tries) + 1)};
      -- psl f_last_try : assert always {timeout and last_try_o and not rst_i} |=>
      --    {rst_i = '1' or (rto_cnt = 0 and tries = prev(tries))};
      -- psl f_count : assert always rto_cnt > 0 -> f_since >= (rto_cnt - 1) * G_TICK + tick_cnt;
      -- psl f_spacing : assert always timeout = '1' -> f_since >= (G_RTO_MS - 1) * G_TICK - 1;

      -- psl c_timeout : cover {timeout and not rst_i};
      -- psl c_last : cover {timeout and last_try_o and not rst_i};
      -- psl c_restart : cover {restart_i and not rst_i; tick and armed_i};
      -- psl c_deferred : cover {tick_cnt = G_TICK - 1 and hold_i = '1' and armed_i = '1' and
      --    rto_cnt = G_RTO_MS - 1 and rst_i = '0'};
   end generate gen_formal;

end architecture synthesis;
