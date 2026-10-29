-- The TCP server's retransmission timer (src/eth/eth_tcp_timer.vhd), with
-- its properties, for SymbiYosys. Every input is free, but for the
-- timer's contract: what the connection tells it comes only in the cycle
-- after it was held or ran out. A millisecond is 3 cycles, the timeout 2
-- milliseconds, and the tries 3, so that the solver soon reaches the last
-- try; the properties do not depend on the numbers.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_eth_tcp_timer is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      armed_i     : in  std_logic;
      hold_i      : in  std_logic;
      restart_i   : in  std_logic;
      tries_clr_i : in  std_logic
   );
end entity formal_eth_tcp_timer;

architecture synthesis of formal_eth_tcp_timer is

   signal timeout  : std_logic;
   signal last_try : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_pulses : assume always {not hold_i and not timeout} |=>
   --    {not restart_i and not tries_clr_i};


   i_eth_tcp_timer : entity work.eth_tcp_timer
      generic map (
         G_TICK   => 3,
         G_RTO_MS => 2,
         G_TRIES  => 3,
         G_FORMAL => true
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         armed_i     => armed_i,
         hold_i      => hold_i,
         restart_i   => restart_i,
         tries_clr_i => tries_clr_i,
         timeout_o   => timeout,
         last_try_o  => last_try
      ); -- i_eth_tcp_timer

end architecture synthesis;
